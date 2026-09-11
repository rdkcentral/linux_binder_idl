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
# Variants whose derivation is EXPECTED to disagree with the kernel. Not a
# skip and not a failure: a checked assertion that the trap the docs describe
# is real. See prepare_variant.
declare -A EXPECTED_VARIANT=()

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
#
# With <derive> non-empty the build is invoked WITHOUT TARGET_LIB32_VERSION or
# BINDER_IPC_32BIT, so it has to work both out from the toolchain — the path a
# plain `./build-linux-binder-aidl.sh` takes. That derivation is what selects
# the protocol for every integrator who does not pass the flags, so it is what
# shipped the protocol-7-on-64-bit default (#54); the explicit variants below
# supply both values and therefore cannot exercise it.
prepare_variant() {   # <arch> <protocol> <busybox> [derive]
    local arch="$1" proto="$2" bb="$3" derive="${4:-}"
    local key="$1-p$2${derive:+-derived}"
    VARIANT_INITRAMFS=""; VARIANT_SKIP=""; VARIANT_EXPECTED=""
    if [ -n "${INITRAMFS_CACHE[${key}]:-}" ]; then VARIANT_INITRAMFS="${INITRAMFS_CACHE[${key}]}"; return 0; fi
    if [ -n "${EXPECTED_VARIANT[${key}]:-}" ]; then VARIANT_SKIP="${EXPECTED_VARIANT[${key}]}"; VARIANT_EXPECTED=1; return 1; fi
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
    # usual state after installing a 32-bit libc without them.
    if [ -n "${mflag}" ] && \
       ! printf '#include <errno.h>\nint main(){return 0;}\n' | ${CXX} ${mflag} -x c++ - -o /dev/null 2>/dev/null; then
        SKIPPED_VARIANT[${key}]="no usable 32-bit toolchain — run tests/install.sh --with-32bit (libc6-dev-i386 + lib32stdc++ + linux-libc-dev:i386)"
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
    # Derived runs pass neither flag; the toolchain in CC/CXX is the only input.
    local -a proto_env=(TARGET_LIB32_VERSION="${lib32}" BINDER_IPC_32BIT="${ipc32}")
    [ -n "${derive}" ] && proto_env=()
    echo "  building ${arch} protocol-${proto} binder SDK${derive:+ (derived from the toolchain)} ..."
    if ! (cd "${REPO_ROOT}" && \
          env BUILD_DIR="${sdk_build}" OUT_DIR="${sdk_out}" \
          CC="${CC}${mflag:+ ${mflag}}" CXX="${CXX}${mflag:+ ${mflag}}" \
          "${proto_env[@]}" \
          ./build-linux-binder-aidl.sh no-host-aidl) >"${WORK}/sdk-${key}.log" 2>&1; then
        [ "${KEEP}" = true ] || tail -15 "${WORK}/sdk-${key}.log" | sed 's/^/        /'
        fail "binder SDK build failed for ${arch}/protocol-${proto} (log: ${WORK}/sdk-${key}.log, kept with --keep)"
    fi

    # Assert the derivation picked the protocol this kernel serves, before the
    # boot does it the slow way. A wrong answer here is the field failure
    # (`protocol(7) does not match user space protocol(8)`) waiting to happen,
    # and naming it at configure level makes the cause obvious in CI output.
    if [ -n "${derive}" ]; then
        # Read the build's own statement of what it selected. The CMake cache is
        # not usable for this: BINDER_IPC_32BIT is a plain set(), so it lands in
        # the cache only when passed with -D — exactly what a derived run does
        # not do.
        local got_proto
        got_proto="$(sed -n 's/.*binder wire protocol: \([78]\).*/\1/p' "${WORK}/sdk-${key}.log" | head -1)"

        # Derivation cannot reach protocol 7 — the default is protocol 8 on
        # every toolchain (#72), because bitness cannot select the protocol and
        # a toolchain-derived default therefore has to be wrong somewhere. It is
        # wrong here, on the legacy kernel, and that is deliberate: the rare and
        # shrinking case is the one that must state its switch. Assert it rather
        # than report a build failure, and fail loudly if it ever stops being
        # true, because the row A guidance would then be stale.
        if [ "${proto}" = "7" ]; then
            if [ "${got_proto}" = "8" ]; then
                EXPECTED_VARIANT[${key}]="derivation gave protocol 8 against a protocol-7 kernel, as documented — a legacy platform must state -DBINDER_IPC_32BIT=ON"
                VARIANT_SKIP="${EXPECTED_VARIANT[${key}]}"; VARIANT_EXPECTED=1
                return 1
            fi
            fail "derivation gave protocol ${got_proto:-<none reported>} against a protocol-7 kernel. The default is protocol 8 on every toolchain; if that changed deliberately, the row A guidance in PROTOCOL.md and BUILD.md is now stale (log: ${WORK}/sdk-${key}.log)"
        fi

        if [ "${got_proto}" != "${proto}" ]; then
            fail "derived protocol is wrong for ${key}: a ${arch} toolchain selected protocol ${got_proto:-<none reported>}, but this kernel serves protocol ${proto} (log: ${WORK}/sdk-${key}.log)"
        fi
        echo "    derived protocol ${got_proto} matches the kernel"
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

# A 32-bit busybox for a rootfs whose guest kernel is 64-bit. build-kernels.sh
# stages one beside every non-x86_64 bzImage, so any i386 kernel directory
# supplies it; without one the mixed pairing skips rather than failing.
find_busybox32() {
    local k d c
    for k in "${KERNELS_LIST[@]}"; do
        d="$(dirname "${k}")"
        c="${d}/busybox"
        [ -x "${c}" ] || continue
        # A busybox staged beside an i386 kernel is an i386 busybox, by
        # construction. prepare_variant re-checks the ELF class anyway, so a
        # wrong one is caught there rather than reaching the guest.
        [ "$(variant_field "${d}" arch x86_64)" = "i386" ] && { echo "${c}"; return 0; }
    done
    return 1
}

# Assemble a rootfs carrying BOTH bitnesses for one kernel: the native SDK at
# /opt/binder and the 32-bit one at /opt/binder32, each with its own build of
# the test binary rpath'd to its own libs. Sets VARIANT_INITRAMFS.
#
# This is what the single-bitness rows cannot show. They transact with a proxy
# back into the same process, so both ends are always the same build; here the
# caller and the callee are different ELF classes and the kernel has to
# translate between them, which is the whole reason protocol 8 exists.
prepare_mixed() {   # <proto> <busybox-64> <busybox-32>
    local proto="$1" bb64="$2" bb32="$3"
    local key="mixed-p${proto}"
    VARIANT_INITRAMFS=""; VARIANT_SKIP=""; VARIANT_EXPECTED=""
    if [ -n "${INITRAMFS_CACHE[${key}]:-}" ]; then VARIANT_INITRAMFS="${INITRAMFS_CACHE[${key}]}"; return 0; fi
    if [ -n "${SKIPPED_VARIANT[${key}]:-}" ]; then VARIANT_SKIP="${SKIPPED_VARIANT[${key}]}"; return 1; fi

    # Both userspaces, built by the existing per-variant path so they are the
    # same artefacts the single-bitness rows use, and cached alongside them.
    prepare_variant x86_64 "${proto}" "${bb64}" || { VARIANT_SKIP="64-bit userspace: ${VARIANT_SKIP}"; SKIPPED_VARIANT[${key}]="${VARIANT_SKIP}"; return 1; }
    prepare_variant i386   "${proto}" "${bb32}" || { VARIANT_SKIP="32-bit userspace: ${VARIANT_SKIP}"; SKIPPED_VARIANT[${key}]="${VARIANT_SKIP}"; return 1; }

    local sdk64="${WORK}/sdk-x86_64-p${proto}" sdk32="${WORK}/sdk-i386-p${proto}"
    local root="${WORK}/rootfs-${key}"
    rm -rf "${root}"
    mkdir -p "${root}"/{bin,sbin,proc,sys,dev,lib,lib64} \
             "${root}"/opt/binder/{bin,lib} "${root}"/opt/binder32/{bin,lib}
    cp "${bb64}" "${root}/bin/busybox"
    local a; for a in sh mount ln sleep poweroff mkdir cat grep; do ln -sf busybox "${root}/bin/${a}"; done

    cp -a "${sdk64}/lib/." "${root}/opt/binder/lib/"
    cp -a "${sdk32}/lib/." "${root}/opt/binder32/lib/"
    cp "${sdk64}/bin/servicemanager" "${root}/opt/binder/bin/servicemanager"

    # One build of the test binary per bitness, each resolving its own SDK.
    local inc64="" inc32="" _c
    for _c in "${sdk64}/include/binder_sdk" "${sdk64}/include"; do [ -d "${_c}" ] && { inc64="${_c}"; break; }; done
    for _c in "${sdk32}/include/binder_sdk" "${sdk32}/include"; do [ -d "${_c}" ] && { inc32="${_c}"; break; }; done
    [ -n "${inc64}" ] && [ -n "${inc32}" ] || { VARIANT_SKIP="binder SDK headers missing for the mixed rootfs"; SKIPPED_VARIANT[${key}]="${VARIANT_SKIP}"; return 1; }

    ${CXX} -std=c++17 -O1 -Wno-attributes -Wno-write-strings -Wno-return-type \
        "${HERE}/binder_roundtrip.cpp" -I"${inc64}" -L"${sdk64}/lib" \
        -lbinder -lutils -lbase -lcutils -llog -Wl,-rpath,/opt/binder/lib \
        -o "${root}/opt/binder/bin/binder_roundtrip" 2>"${WORK}/mixed-cc64.log" \
        || { VARIANT_SKIP="64-bit test binary failed to build (log: ${WORK}/mixed-cc64.log)"; SKIPPED_VARIANT[${key}]="${VARIANT_SKIP}"; return 1; }

    ${CXX} -m32 -std=c++17 -O1 -Wno-attributes -Wno-write-strings -Wno-return-type \
        "${HERE}/binder_roundtrip.cpp" -I"${inc32}" -L"${sdk32}/lib" \
        -lbinder -lutils -lbase -lcutils -llog -Wl,-rpath,/opt/binder32/lib \
        -o "${root}/opt/binder32/bin/binder_roundtrip" 2>"${WORK}/mixed-cc32.log" \
        || { VARIANT_SKIP="32-bit test binary failed to build (log: ${WORK}/mixed-cc32.log)"; SKIPPED_VARIANT[${key}]="${VARIANT_SKIP}"; return 1; }

    cp "${HERE}/guest-init.sh" "${root}/init"; chmod +x "${root}/init"
    copy_deps "${root}/opt/binder/bin/binder_roundtrip"   "${root}" "${sdk64}/lib"
    copy_deps "${root}/opt/binder32/bin/binder_roundtrip" "${root}" "${sdk32}/lib"
    copy_deps "${root}/opt/binder/bin/servicemanager"     "${root}" "${sdk64}/lib"
    copy_deps "${bb64}"                                   "${root}" "${sdk64}/lib"

    local img="${WORK}/initramfs-${key}.cpio.gz"
    (cd "${root}" && find . | cpio -o -H newc 2>/dev/null | gzip) > "${img}"
    INITRAMFS_CACHE[${key}]="${img}"
    VARIANT_INITRAMFS="${img}"
    return 0
}

# Boot one prepared variant and score it. VARIANT_INITRAMFS must be set.
boot_variant() {   # <kimg> <qemu-bin> <label> <log-name> [extra-cmdline]
    local kimg="$1" qemu_bin="$2" vlabel="$3" log="${WORK}/qemu-$4.log" extra="${5:-}"
    timeout "${TIMEOUT}" "${qemu_bin}" \
        -m 512 -no-reboot -nographic \
        -kernel "${kimg}" -initrd "${VARIANT_INITRAMFS}" \
        -append "console=ttyS0 rdinit=/init panic=-1 loglevel=3${extra:+ ${extra}}" \
        >"${log}" 2>&1 || true

    if grep -q 'QEMU_BINDER_RESULT: PASS' "${log}"; then
        echo "  PASS  ${vlabel}: $(grep -o 'QEMU_BINDER_RESULT: PASS.*' "${log}" | head -n 1)"
        PASS=$((PASS+1))
    elif grep -q 'QEMU_BINDER_RESULT: FAIL' "${log}"; then
        echo "  FAIL  ${vlabel}: $(grep -o 'QEMU_BINDER_RESULT: FAIL.*' "${log}" | head -n 1)"
        FAIL=$((FAIL+1))
    else
        echo "  FAIL  ${vlabel}: no result sentinel (boot/timeout?) — see ${log}"
        [ "${KEEP}" = true ] || tail -15 "${log}" | sed 's/^/        /'
        FAIL=$((FAIL+1))
    fi
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
    # Two passes per kernel: the explicit one pins both flags and proves the
    # protocols interoperate; the derived one passes neither and proves the
    # build picks the right protocol on its own — the path every integrator
    # who does not set the flags takes.
    for mode in "" derive; do
        vlabel="${label}${mode:+ [derived]}"
        if ! prepare_variant "${arch}" "${proto}" "${bb}" "${mode}"; then
            if [ -n "${VARIANT_EXPECTED}" ]; then
                # The derivation is wrong here by design, and proving it is the
                # test. Booting it would only reproduce the mismatch the
                # protocol-7-userspace negative case already covers.
                echo "  PASS  ${vlabel}: ${VARIANT_SKIP}"; PASS=$((PASS+1))
            else
                echo "  SKIP  ${vlabel}: ${VARIANT_SKIP}"; SKIPPED=$((SKIPPED+1))
            fi
            continue
        fi

        echo "[qemu] booting kernel: ${vlabel} (${arch}, protocol ${proto})"
        boot_variant "${kimg}" "${qemu_bin}" "${vlabel}" "${label}${mode:+-derived}"
    done

    # A third pass on a 64-bit kernel: 32-bit userspace over it. This is the
    # configuration recommended on a 64-bit platform — middleware and vendor
    # both 32-bit — and it runs the binder driver's COMPAT path, which is
    # distinct code from both native pairings and which nothing else here
    # reaches. The userspace is the (i386, protocol 8) variant already built
    # for the 32-bit-kernel rows, so this is a boot, not another build.
    if [ "${arch}" = "x86_64" ] && [ "${proto}" = "8" ]; then
        vlabel="${label} [32-bit userspace]"
        bb32="$(find_busybox32 || true)"
        if [ -z "${bb32}" ]; then
            echo "  SKIP  ${vlabel}: no 32-bit busybox staged — build an i386 kernel variant first"
            SKIPPED=$((SKIPPED+1))
        elif ! prepare_variant i386 "${proto}" "${bb32}"; then
            echo "  SKIP  ${vlabel}: ${VARIANT_SKIP}"; SKIPPED=$((SKIPPED+1))
        else
            echo "[qemu] booting kernel: ${vlabel} (${arch} kernel, i386 userspace, protocol ${proto})"
            boot_variant "${kimg}" "${qemu_bin}" "${vlabel}" "${label}-user32"
        fi

        # And the pairing the single-bitness rows cannot show: a 32-bit and a
        # 64-bit process transacting with EACH OTHER over this kernel. Both
        # directions, because a reply crosses the boundary as well as a call.
        # This is the configuration a 64-bit vendor layer with 32-bit
        # middleware would ship, and the reason protocol 8 exists at all.
        for scen in server64-client32 server32-client64; do
            vlabel="${label} [${scen}]"
            if [ -z "${bb32}" ]; then
                echo "  SKIP  ${vlabel}: no 32-bit busybox staged — build an i386 kernel variant first"
                SKIPPED=$((SKIPPED+1)); continue
            fi
            if ! prepare_mixed "${proto}" "${bb}" "${bb32}"; then
                echo "  SKIP  ${vlabel}: ${VARIANT_SKIP}"; SKIPPED=$((SKIPPED+1)); continue
            fi
            echo "[qemu] booting kernel: ${vlabel} (${arch} kernel, mixed 32/64 userspace, protocol ${proto})"
            boot_variant "${kimg}" "${qemu_bin}" "${vlabel}" "${label}-${scen}" "binder_scenario=${scen}"
        done
    fi
done

echo ""
echo "  qemu binder test: ${PASS} passed, ${FAIL} failed, ${SKIPPED} skipped"
[ "${KEEP}" = true ] && echo "  work dir kept: ${WORK}"
[ "${FAIL}" -eq 0 ]
