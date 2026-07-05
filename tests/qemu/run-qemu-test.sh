#!/usr/bin/env bash
#/**
# * Copyright 2026 RDK Management
# *
# * Licensed under the Apache License, Version 2.0 (the "License");
# * you may not use this file except in compliance with the License.
# * You may obtain a copy of the License at
# *
# * http://www.apache.org/licenses/LICENSE-2.0
# *
# * Unless required by applicable law or agreed to in writing, software
# * distributed under the License is distributed on an "AS IS" BASIS,
# * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# * See the License for the specific language governing permissions and
# * limitations under the License.
# *
# * SPDX-License-Identifier: Apache-2.0
# */
#
# Optional QEMU binder round-trip test. Boots each target kernel with a tiny
# initramfs (binder SDK + servicemanager + binder_roundtrip) and checks the
# guest completes a binder transaction on that kernel.
#
# This is the runtime gate for the kernel-floor / protocol / bitness work
# (linux_binder_idl#35 / #36). Docker can't do it — containers share the host
# kernel — so we boot real kernels under QEMU.
#
# Usage:
#   ./tests/qemu/run-qemu-test.sh                 # all kernels under tests/qemu/kernels/
#   ./tests/qemu/run-qemu-test.sh --kernel <bzImage>
#   KERNELS="a/bzImage b/bzImage" ./tests/qemu/run-qemu-test.sh
#   ./tests/qemu/run-qemu-test.sh --keep          # keep the work dir
#
# Build kernels first with ./tests/qemu/build-kernels.sh (or supply your own).
# Exit: 0 = all booted kernels passed (or cleanly skipped); 1 = a failure.
set -uo pipefail

HERE="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
KERNEL_DIR="${HERE}/kernels"
QEMU="${QEMU:-qemu-system-x86_64}"
KEEP=false
KERNEL_ARG=""
TIMEOUT="${QEMU_TIMEOUT:-90}"

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel) [ $# -ge 2 ] || { echo "--kernel needs a path" >&2; exit 2; }; KERNEL_ARG="$2"; shift 2 ;;
        --keep)   KEEP=true; shift ;;
        -h|--help) sed -n '20,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

skip() { echo "  SKIP  qemu binder test — $1"; exit 0; }   # absence of tooling is not a failure
fail() { echo "  FAIL  qemu binder test — $1"; exit 1; }   # once opted in, real errors must fail

# ---- Prerequisites (skip cleanly when missing) -----------------------------
CXX="${CXX:-g++}"
for tool in "${QEMU}" busybox cpio "${CXX}" timeout gzip ldd; do
    command -v "${tool}" >/dev/null 2>&1 || skip "${tool} not installed"
done
BUSYBOX="$(command -v busybox)"

# Collect kernels.
KERNELS_LIST=()
if [ -n "${KERNEL_ARG}" ]; then
    KERNELS_LIST=("${KERNEL_ARG}")
elif [ -n "${KERNELS:-}" ]; then
    # shellcheck disable=SC2206
    KERNELS_LIST=(${KERNELS})
else
    while IFS= read -r k; do KERNELS_LIST+=("$k"); done \
        < <(find "${KERNEL_DIR}" -name 'bzImage' -type f 2>/dev/null | sort)
fi
[ "${#KERNELS_LIST[@]}" -gt 0 ] || skip "no kernels found (run ./tests/qemu/build-kernels.sh or pass --kernel/KERNELS)"

# ---- Binder target build (build-linux-binder-aidl.sh) ----------------------
SM_BIN="${REPO_ROOT}/out/target/bin/servicemanager"
if [ ! -x "${SM_BIN}" ]; then
    echo "  building binder target libs (build-linux-binder-aidl.sh) ..."
    (cd "${REPO_ROOT}" && ./build-linux-binder-aidl.sh) >/dev/null 2>&1 \
        || fail "build-linux-binder-aidl.sh failed (binder target libs could not be built)"
fi
SDK_LIB="${REPO_ROOT}/out/target/lib"
# Headers install under out/target/include; accept a couple of layouts so an
# upstream header-path change doesn't silently skip the test.
SDK_INC=""
for _c in "${REPO_ROOT}/out/target/include/binder_sdk" "${REPO_ROOT}/out/target/include"; do
    [ -d "${_c}" ] && { SDK_INC="${_c}"; break; }
done
[ -d "${SDK_LIB}" ] && [ -n "${SDK_INC}" ] || skip "binder target libs/headers not staged (${SDK_LIB})"
[ -x "${SM_BIN}" ] || skip "servicemanager not built at ${SM_BIN}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qemu-binder.XXXXXX")"
cleanup() { [ "${KEEP}" = true ] || rm -rf "${WORK}"; }
trap cleanup EXIT
ROOT="${WORK}/rootfs"

# ---- Build the in-guest test binary ----------------------------------------
echo "  compiling binder_roundtrip ..."
"${CXX}" -std=c++17 -O1 -Wno-attributes -Wno-write-strings -Wno-return-type \
    "${HERE}/binder_roundtrip.cpp" \
    -I"${SDK_INC}" -L"${SDK_LIB}" -lbinder -lutils -lbase -lcutils -llog \
    -Wl,-rpath,/opt/binder/lib -o "${WORK}/binder_roundtrip" \
    || fail "binder_roundtrip failed to compile/link against the SDK (ABI or flags regression?)"

# ---- Assemble the initramfs ------------------------------------------------
mkdir -p "${ROOT}"/{bin,sbin,proc,sys,dev,opt/binder/bin,opt/binder/lib,lib,lib64}
cp "${BUSYBOX}" "${ROOT}/bin/busybox"
for a in sh mount ln sleep poweroff mkdir cat; do ln -sf busybox "${ROOT}/bin/${a}"; done
cp "${WORK}/binder_roundtrip" "${ROOT}/opt/binder/bin/"
cp "${SM_BIN}"                "${ROOT}/opt/binder/bin/servicemanager"
cp -a "${SDK_LIB}/." "${ROOT}/opt/binder/lib/"
cp "${HERE}/guest-init.sh" "${ROOT}/init"; chmod +x "${ROOT}/init"

# Copy each binary's SYSTEM shared-lib closure + the ELF interpreter into the
# rootfs, preserving paths, so the guest userspace resolves at runtime. SDK libs
# are skipped here — they're already staged at /opt/binder/lib and found via the
# binary's rpath; copying them under their host repo paths would only bloat the
# initramfs and not match the guest layout.
copy_deps() {
    local bin="$1" dep
    LD_LIBRARY_PATH="${SDK_LIB}" ldd "${bin}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' \
    | while read -r dep; do
        [ -f "${dep}" ] || continue
        case "${dep}" in "${SDK_LIB}"/*) continue ;; esac   # SDK libs already at /opt/binder/lib
        mkdir -p "${ROOT}$(dirname "${dep}")"
        cp -n "${dep}" "${ROOT}${dep}" 2>/dev/null || true
    done
}
copy_deps "${WORK}/binder_roundtrip"
copy_deps "${SM_BIN}"
copy_deps "${BUSYBOX}"

INITRAMFS="${WORK}/initramfs.cpio.gz"
(cd "${ROOT}" && find . | cpio -o -H newc 2>/dev/null | gzip) > "${INITRAMFS}"

# ---- Boot each kernel ------------------------------------------------------
FAIL=0; PASS=0; SKIPPED=0
for kimg in "${KERNELS_LIST[@]}"; do
    if [ ! -f "${kimg}" ]; then echo "  SKIP  ${kimg} (not found)"; SKIPPED=$((SKIPPED+1)); continue; fi
    label="$(basename "$(dirname "${kimg}")")"
    log="${WORK}/qemu-${label}.log"
    echo "[qemu] booting kernel: ${label} (${kimg})"
    timeout "${TIMEOUT}" "${QEMU}" \
        -m 512 -no-reboot -nographic \
        -kernel "${kimg}" -initrd "${INITRAMFS}" \
        -append "console=ttyS0 rdinit=/init panic=-1 loglevel=3" \
        >"${log}" 2>&1 || true

    if grep -q 'QEMU_BINDER_RESULT: PASS' "${log}"; then
        echo "  PASS  ${label}: $(grep -o 'QEMU_BINDER_RESULT: PASS.*' "${log}" | head -1)"
        PASS=$((PASS+1))
    elif grep -q 'QEMU_BINDER_RESULT: FAIL' "${log}"; then
        echo "  FAIL  ${label}: $(grep -o 'QEMU_BINDER_RESULT: FAIL.*' "${log}" | head -1)"
        FAIL=$((FAIL+1))
    else
        echo "  FAIL  ${label}: no result sentinel (boot/timeout?) — see ${log}"
        [ "${KEEP}" = true ] || tail -15 "${log}" | sed 's/^/        /'
        FAIL=$((FAIL+1))
    fi
done

echo ""
echo "  qemu binder test: ${PASS} passed, ${FAIL} failed, ${SKIPPED} skipped"
[ "${KEEP}" = true ] && echo "  work dir kept: ${WORK}"
[ "${FAIL}" -eq 0 ]
