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
# Optional QEMU binder round-trip test. For each target kernel it builds a
# userspace at that kernel's binder protocol, packs it into a tiny initramfs
# (binder SDK + servicemanager + binder_roundtrip), boots the kernel, and
# checks the guest completes a binder transaction.
#
# Each kernel's tests/qemu/kernels/<label>/variant file records its guest arch
# and protocol; the matching QEMU binary and a same-protocol SDK are selected
# from it. A variant the host cannot build skips cleanly.
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
#   QEMU=qemu-system-i386 ./tests/qemu/run-qemu-test.sh   # pin the QEMU binary
#
# Build kernels first with ./tests/qemu/build-kernels.sh (or supply your own).
# Exit: 0 = all booted kernels passed (or cleanly skipped); 1 = a failure.
set -uo pipefail

HERE="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
KERNEL_DIR="${HERE}/kernels"
# Unset by default: the QEMU binary follows each kernel's guest arch. Setting
# QEMU pins every kernel to one binary.
QEMU="${QEMU:-}"
KEEP=false
KERNEL_ARG=""
TIMEOUT="${QEMU_TIMEOUT:-90}"

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel) [ $# -ge 2 ] || { echo "--kernel needs a path" >&2; exit 2; }; KERNEL_ARG="$2"; shift 2 ;;
        --keep)   KEEP=true; shift ;;
        -h|--help) sed -n '20,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

skip() { echo "  SKIP  qemu binder test — $1"; exit 0; }   # absence of tooling is not a failure
fail() { echo "  FAIL  qemu binder test — $1"; exit 1; }   # once opted in, real errors must fail

# ---- Prerequisites (skip cleanly when missing) -----------------------------
# QEMU and busybox are checked per variant instead — a 32-bit guest needs a
# different binary and a different busybox than a 64-bit one.
CXX="${CXX:-g++}"
CC="${CC:-gcc}"
# A Yocto-style CC/CXX carries embedded flags ("arm-...-gcc --sysroot=..."), so
# resolve the binary from the first word before asking whether it exists.
CC_BIN="${CC%% *}"
CXX_BIN="${CXX%% *}"
# cmake/make included: this script builds the binder SDK itself, so their
# absence is missing optional tooling to skip on, not a build failure to report.
for tool in cpio "${CC_BIN}" "${CXX_BIN}" cmake make timeout gzip ldd; do
    command -v "${tool}" >/dev/null 2>&1 || skip "${tool} not installed"
done
BUSYBOX="$(command -v busybox || true)"

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qemu-binder.XXXXXX")"
cleanup() { [ "${KEEP}" = true ] || rm -rf "${WORK}"; }
trap cleanup EXIT

# ---- Per-variant guest userspace -------------------------------------------
# The binder wire protocol is compiled into libbinder, so a protocol-7 kernel
# needs a protocol-7 userspace and a protocol-8 kernel needs a protocol-8 one.
# Each (arch, protocol) variant therefore gets its own SDK build, test binary
# and initramfs, built into the work dir so a staged out/target of unknown
# protocol can never satisfy the run. Variants are cached across the kernels
# that share them.
declare -A INITRAMFS_CACHE=()
declare -A SKIPPED_VARIANT=()

# Read a field from a kernel's `variant` file, falling back for kernels built
# before build-kernels.sh started writing one.
variant_field() {   # <kernel-dir> <key> <fallback>
    local val=""
    [ -f "$1/variant" ] && val="$(sed -n "s/^$2=//p" "$1/variant" | head -1)"
    echo "${val:-$3}"
}

# ELF class of a binary, from byte 4 of the header: 32, 64, or empty. Used to
# reject a host busybox of the wrong bitness for the guest — it would otherwise
# be copied in silently and the guest would fail to exec /init.
elf_class() {
    case "$(od -An -tu1 -j4 -N1 "$1" 2>/dev/null | tr -d ' ')" in
        1) echo 32 ;; 2) echo 64 ;; *) echo "" ;;
    esac
}

# Copy a binary's SYSTEM shared-lib closure + the ELF interpreter into the
# rootfs, preserving paths, so the guest userspace resolves at runtime. SDK libs
# are skipped — they're already staged at /opt/binder/lib and found via the
# binary's rpath; copying them under their host repo paths would only bloat the
# initramfs and not match the guest layout.
copy_deps() {   # <binary> <rootfs> <sdk-lib-dir>
    local bin="$1" root="$2" sdk="$3" dep
    LD_LIBRARY_PATH="${sdk}" ldd "${bin}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' \
    | while read -r dep; do
        [ -f "${dep}" ] || continue
        case "${dep}" in "${sdk}"/*) continue ;; esac   # SDK libs already at /opt/binder/lib
        mkdir -p "${root}$(dirname "${dep}")"
        cp -n "${dep}" "${root}${dep}" 2>/dev/null || true
    done
}

# Build the userspace for one variant. Sets VARIANT_INITRAMFS on success, or
# VARIANT_SKIP with a reason when the host can't produce it.
prepare_variant() {   # <arch> <protocol> <busybox>
    local arch="$1" proto="$2" bb="$3" key="$1-p$2"
    VARIANT_INITRAMFS=""; VARIANT_SKIP=""
    if [ -n "${INITRAMFS_CACHE[${key}]:-}" ]; then VARIANT_INITRAMFS="${INITRAMFS_CACHE[${key}]}"; return 0; fi
    if [ -n "${SKIPPED_VARIANT[${key}]:-}" ]; then VARIANT_SKIP="${SKIPPED_VARIANT[${key}]}"; return 1; fi

    local mflag="" lib32=OFF ipc32=OFF
    [ "${arch}" = "i386" ] && { mflag="-m32"; lib32=ON; }
    [ "${proto}" = "7" ]  && { ipc32=ON; lib32=ON; }   # protocol 7 implies a 32-bit target

    # Protocol 7 only exists on a 32-bit kernel, so a protocol-7 guest is i386.
    # Anything else is a mislabelled kernel, and building for it would produce
    # exactly the silent mismatch this harness is meant to catch.
    if [ "${proto}" = "7" ] && [ "${arch}" != "i386" ]; then
        SKIPPED_VARIANT[${key}]="protocol 7 declared on a ${arch} guest — CONFIG_ANDROID_BINDER_IPC_32BIT cannot be set on a 64-bit kernel"
        VARIANT_SKIP="${SKIPPED_VARIANT[${key}]}"; return 1
    fi

    # Probe with <errno.h>: it reaches asm/errno.h, so this catches a host that
    # can link a bare -m32 binary but has no i386 kernel headers — which is the
    # usual state after installing only gcc-multilib.
    if [ -n "${mflag}" ] && \
       ! printf '#include <errno.h>\nint main(){return 0;}\n' | ${CXX} ${mflag} -x c++ - -o /dev/null 2>/dev/null; then
        SKIPPED_VARIANT[${key}]="no usable 32-bit toolchain — see tests/install.sh (gcc-multilib/g++-multilib + linux-libc-dev:i386)"
        VARIANT_SKIP="${SKIPPED_VARIANT[${key}]}"; return 1
    fi

    local want=64; [ "${arch}" = "i386" ] && want=32
    if [ -z "${bb}" ] || [ ! -x "${bb}" ]; then
        SKIPPED_VARIANT[${key}]="no busybox available for the ${arch} guest rootfs"
        VARIANT_SKIP="${SKIPPED_VARIANT[${key}]}"; return 1
    fi
    if [ "$(elf_class "${bb}")" != "${want}" ]; then
        SKIPPED_VARIANT[${key}]="busybox at ${bb} is not ${want}-bit — a ${arch} guest needs its own (build-kernels.sh stages one next to the bzImage)"
        VARIANT_SKIP="${SKIPPED_VARIANT[${key}]}"; return 1
    fi

    local sdk_out="${WORK}/sdk-${key}" sdk_build="${WORK}/build-${key}"
    echo "  building ${arch} protocol-${proto} binder SDK ..."
    if ! (cd "${REPO_ROOT}" && \
          BUILD_DIR="${sdk_build}" OUT_DIR="${sdk_out}" \
          CC="${CC}${mflag:+ ${mflag}}" CXX="${CXX}${mflag:+ ${mflag}}" \
          TARGET_LIB32_VERSION="${lib32}" BINDER_IPC_32BIT="${ipc32}" \
          ./build-linux-binder-aidl.sh no-host-aidl) >"${WORK}/sdk-${key}.log" 2>&1; then
        [ "${KEEP}" = true ] || tail -15 "${WORK}/sdk-${key}.log" | sed 's/^/        /'
        fail "binder SDK build failed for ${arch}/protocol-${proto} (log: ${WORK}/sdk-${key}.log, kept with --keep)"
    fi

    local sdk_lib="${sdk_out}/lib" sdk_inc="" sm_bin="${sdk_out}/bin/servicemanager"
    # Headers install under <out>/include; accept a couple of layouts so an
    # upstream header-path change doesn't silently skip the test.
    for _c in "${sdk_out}/include/binder_sdk" "${sdk_out}/include"; do
        [ -d "${_c}" ] && { sdk_inc="${_c}"; break; }
    done
    [ -d "${sdk_lib}" ] && [ -n "${sdk_inc}" ] || fail "binder SDK not staged for ${key} (${sdk_lib})"
    [ -x "${sm_bin}" ] || fail "servicemanager not built for ${key} at ${sm_bin}"

    echo "  compiling binder_roundtrip (${arch}) ..."
    ${CXX} ${mflag} -std=c++17 -O1 -Wno-attributes -Wno-write-strings -Wno-return-type \
        "${HERE}/binder_roundtrip.cpp" \
        -I"${sdk_inc}" -L"${sdk_lib}" -lbinder -lutils -lbase -lcutils -llog \
        -Wl,-rpath,/opt/binder/lib -o "${WORK}/binder_roundtrip-${key}" \
        || fail "binder_roundtrip failed to compile/link against the ${key} SDK (ABI or flags regression?)"

    local root="${WORK}/rootfs-${key}"
    mkdir -p "${root}"/{bin,sbin,proc,sys,dev,opt/binder/bin,opt/binder/lib,lib,lib64}
    cp "${bb}" "${root}/bin/busybox"
    local a; for a in sh mount ln sleep poweroff mkdir cat; do ln -sf busybox "${root}/bin/${a}"; done
    cp "${WORK}/binder_roundtrip-${key}" "${root}/opt/binder/bin/binder_roundtrip"
    cp "${sm_bin}"                       "${root}/opt/binder/bin/servicemanager"
    cp -a "${sdk_lib}/." "${root}/opt/binder/lib/"
    cp "${HERE}/guest-init.sh" "${root}/init"; chmod +x "${root}/init"

    copy_deps "${WORK}/binder_roundtrip-${key}" "${root}" "${sdk_lib}"
    copy_deps "${sm_bin}"                       "${root}" "${sdk_lib}"
    copy_deps "${bb}"                           "${root}" "${sdk_lib}"

    local img="${WORK}/initramfs-${key}.cpio.gz"
    (cd "${root}" && find . | cpio -o -H newc 2>/dev/null | gzip) > "${img}"
    INITRAMFS_CACHE[${key}]="${img}"
    VARIANT_INITRAMFS="${img}"
    return 0
}

# ---- Boot each kernel ------------------------------------------------------
FAIL=0; PASS=0; SKIPPED=0
for kimg in "${KERNELS_LIST[@]}"; do
    if [ ! -f "${kimg}" ]; then echo "  SKIP  ${kimg} (not found)"; SKIPPED=$((SKIPPED+1)); continue; fi
    kdir="$(dirname "${kimg}")"
    label="$(basename "${kdir}")"
    arch="$(variant_field "${kdir}" arch x86_64)"
    proto="$(variant_field "${kdir}" protocol 8)"

    # A non-native guest ships its own busybox next to the bzImage.
    bb="${kdir}/busybox"; [ -x "${bb}" ] || bb="${BUSYBOX}"

    qemu_bin="${QEMU:-qemu-system-${arch}}"
    if ! command -v "${qemu_bin}" >/dev/null 2>&1; then
        echo "  SKIP  ${label}: ${qemu_bin} not installed"; SKIPPED=$((SKIPPED+1)); continue
    fi
    if ! prepare_variant "${arch}" "${proto}" "${bb}"; then
        echo "  SKIP  ${label}: ${VARIANT_SKIP}"; SKIPPED=$((SKIPPED+1)); continue
    fi

    log="${WORK}/qemu-${label}.log"
    echo "[qemu] booting kernel: ${label} (${arch}, protocol ${proto})"
    timeout "${TIMEOUT}" "${qemu_bin}" \
        -m 512 -no-reboot -nographic \
        -kernel "${kimg}" -initrd "${VARIANT_INITRAMFS}" \
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
