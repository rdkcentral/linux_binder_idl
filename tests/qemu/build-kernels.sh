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
# Build the QEMU test kernel matrix with Buildroot. For each version it builds
# a bootable bzImage with the Binder driver enabled (binder.fragment) and drops
# it at tests/qemu/kernels/<label>/bzImage for run-qemu-test.sh, alongside a
# `variant` file recording the guest arch and binder protocol.
#
# Default guest is x86_64 / protocol 8. A `:ipc32` suffix builds the legacy
# protocol-7 variant, which must be a 32-bit (i386) guest at 4.17 or older. An
# `:i386` suffix builds the third kernel that exists: 32-bit at protocol 8, the
# kernel side of a 32-bit userspace on a modern binder driver.
#
# Buildroot is used only for the KERNEL (its kernel-build plumbing handles the
# cross toolchain + config-fragment merge); the test's userspace comes from the
# repo's own binder SDK, assembled into an initramfs by run-qemu-test.sh.
#
# Usage:
#   ./tests/qemu/build-kernels.sh                 # default matrix
#   VERSIONS="4.9.337 5.10.205 5.15.148" ./tests/qemu/build-kernels.sh
#   BUILDROOT=/path/to/buildroot ./tests/qemu/build-kernels.sh   # reuse a checkout
#
# Heavy + needs network/toolchain; on-demand only. Each version builds in its
# own Buildroot output dir so they don't clobber each other.
set -uo pipefail

HERE="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
OUT="${HERE}/kernels"
FRAGMENT="${HERE}/kconfig/binder.fragment"
IPC32_FRAGMENT="${HERE}/kconfig/binder-ipc32.fragment"

# Default matrix — one stable point release per minor across the supported
# range (4.9 floor → 5.16), plus both 32-bit kernels at the 4.9 floor. Suffixes
# select the guest and the protocol; without one the guest is x86_64 at
# protocol 8.
#   :ipc32  protocol 7 — i386 guest at 4.17 or older, binder-ipc32.fragment
#   :i386   protocol 8 on a 32-bit kernel — i386 guest at 4.18 or newer
VERSIONS="${VERSIONS:-4.9.337 4.9.337:ipc32 5.4.290 5.4.290:i386 5.10.205 5.15.148 5.16.20}"
BR_VERSION="${BR_VERSION:-2024.02.9}"

die()  { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Buildroot refuses to run when LD_LIBRARY_PATH contains the working directory,
# which a trailing ':' (common in CUDA/toolchain profiles) silently produces.
# Drop it rather than fail on the developer's environment.
br_make() { env -u LD_LIBRARY_PATH make -C "${BUILDROOT}" "$@"; }

# Protocol 7 needs CONFIG_ANDROID_BINDER_IPC_32BIT, which upstream declares
# `depends on !64BIT && ANDROID_BINDER_IPC` and removed outright in 4.18. So a
# protocol-7 kernel can only be a 32-bit guest at 4.17 or older; asking for one
# anywhere else silently yields a protocol-8 kernel wearing an -ipc32 label.
ipc32_supported() {
    local major minor
    major="${1%%.*}"; minor="${1#*.}"; minor="${minor%%.*}"
    case "${major}${minor}" in ''|*[!0-9]*) return 1 ;; esac
    [ "${major}" -eq 4 ] && [ "${minor}" -le 17 ]
}

# A 32-bit kernel serves protocol 8 only where the option is gone, i.e. 4.18 and
# newer. It cannot be turned off on an older one: 4.9 declares the symbol as a
# bare `bool` with no prompt string, so it is not user-configurable — kconfig
# discards a "# CONFIG_ANDROID_BINDER_IPC_32BIT is not set" line from a fragment
# and recomputes `default y`. Moving a legacy 32-bit platform to protocol 8 takes
# a kernel patch, not a config change.
guest32_proto8_supported() {
    ! ipc32_supported "$1"
}

# Buildroot needs a normal build toolchain + the usual fetchers.
for t in make gcc g++ wget tar cpio rsync bc flex bison; do
    have "$t" || die "missing build dependency: $t (Buildroot prerequisite)"
done

# Obtain Buildroot (reuse $BUILDROOT if provided).
if [ -n "${BUILDROOT:-}" ]; then
    [ -f "${BUILDROOT}/Makefile" ] || die "BUILDROOT=${BUILDROOT} is not a Buildroot checkout"
else
    BUILDROOT="${HERE}/.buildroot/buildroot-${BR_VERSION}"
    if [ ! -f "${BUILDROOT}/Makefile" ]; then
        mkdir -p "${HERE}/.buildroot"
        echo "[buildroot] fetching ${BR_VERSION} ..."
        wget -qO "${HERE}/.buildroot/br.tar.gz" \
            "https://buildroot.org/downloads/buildroot-${BR_VERSION}.tar.gz" \
            || die "failed to download Buildroot ${BR_VERSION}"
        tar -xzf "${HERE}/.buildroot/br.tar.gz" -C "${HERE}/.buildroot" \
            || die "failed to extract Buildroot tarball (partial download / disk full?)"
    fi
fi
echo "[buildroot] using ${BUILDROOT}"

mkdir -p "${OUT}"
built=0
for spec in ${VERSIONS}; do
    ver="${spec%%:*}"
    ipc32=false
    guest32=false
    case "${spec}" in
        *:ipc32) ipc32=true; guest32=true ;;
        *:i386)  guest32=true ;;
    esac
    if ${ipc32}; then      label="${ver}-ipc32"
    elif ${guest32}; then  label="${ver}-i386"
    else                   label="${ver}"
    fi
    o="${BUILDROOT}/output-${label}"
    dest="${OUT}/${label}"

    echo ""
    echo "=== kernel ${label} ==="

    # Three kernels exist, and the guest arch is not a free choice in any of
    # them. Protocol 7 only exists on a 32-bit kernel at 4.17 or older, so
    # :ipc32 is i386 and version-guarded. A 64-bit kernel can only serve
    # protocol 8, so the plain spec is x86_64. :i386 is the third — a 32-bit
    # kernel at protocol 8 — and is guarded the other way, because the option
    # cannot be cleared on a kernel old enough to have it.
    if ${ipc32}; then
        if ! ipc32_supported "${ver}"; then
            echo "  FAIL  ${label}: :ipc32 needs a 4.9-4.17 kernel — CONFIG_ANDROID_BINDER_IPC_32BIT was removed in 4.18"
            continue
        fi
        arch="i386"; br_arch="BR2_i386=y"$'\n'"BR2_x86_i686=y"
        frags="${FRAGMENT} ${IPC32_FRAGMENT}"
    elif ${guest32}; then
        if ! guest32_proto8_supported "${ver}"; then
            echo "  FAIL  ${label}: :i386 needs a 4.18+ kernel — on 4.17 and older CONFIG_ANDROID_BINDER_IPC_32BIT is a prompt-less 'default y' symbol that a config fragment cannot clear"
            continue
        fi
        arch="i386"; br_arch="BR2_i386=y"$'\n'"BR2_x86_i686=y"
        frags="${FRAGMENT}"
    else
        arch="x86_64"; br_arch="BR2_x86_64=y"
        frags="${FRAGMENT}"
    fi

    # Buildroot defaults BR2_KERNEL_HEADERS_AS_KERNEL=y, taking the toolchain's
    # kernel headers from the custom kernel — then cross-checks them against the
    # selected header *series*, which defaults to the newest Buildroot knows.
    # Building anything but that newest series aborts with "Incorrect selection
    # of kernel headers", so pin the series to the kernel under build.
    hdr="${ver%%.*}_$(x="${ver#*.}"; echo "${x%%.*}")"
    cat > "${o}.config" <<EOF
${br_arch}
BR2_TOOLCHAIN_BUILDROOT_CXX=y
BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_${hdr}=y
BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_CUSTOM_VERSION=y
BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="${ver}"
BR2_LINUX_KERNEL_DEFCONFIG="${arch}"
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="${frags}"
BR2_LINUX_KERNEL_BZIMAGE=y
EOF
    if ! br_make O="${o}" defconfig BR2_DEFCONFIG="${o}.config" >/dev/null 2>&1; then
        echo "  FAIL  ${label}: buildroot defconfig failed"; continue
    fi
    if ! br_make O="${o}" linux >"${o}.build.log" 2>&1; then
        echo "  FAIL  ${label}: kernel build failed — see ${o}.build.log"; continue
    fi

    # Verify the protocol actually landed. kconfig drops an unsatisfiable
    # symbol silently, so without this a mislabelled kernel builds "OK" and the
    # matrix reports coverage it does not have.
    kcfg="$(find "${o}/build" -maxdepth 2 -path '*/linux-*/.config' -type f 2>/dev/null | head -1)"
    if [ -z "${kcfg}" ]; then
        echo "  FAIL  ${label}: merged kernel .config not found — cannot verify the binder protocol"; continue
    fi
    if ${ipc32}; then
        if ! grep -q '^CONFIG_ANDROID_BINDER_IPC_32BIT=y' "${kcfg}"; then
            echo "  FAIL  ${label}: CONFIG_ANDROID_BINDER_IPC_32BIT did not survive the merge — this kernel serves protocol 8"; continue
        fi
    elif grep -q '^CONFIG_ANDROID_BINDER_IPC_32BIT=y' "${kcfg}"; then
        echo "  FAIL  ${label}: CONFIG_ANDROID_BINDER_IPC_32BIT is set on a protocol-8 variant"; continue
    fi

    img="$(find "${o}/images" -name 'bzImage' -type f 2>/dev/null | head -1)"
    if [ -z "${img}" ]; then echo "  FAIL  ${label}: no bzImage produced"; continue; fi
    mkdir -p "${dest}"; cp "${img}" "${dest}/bzImage"

    # Record what this kernel is, so run-qemu-test.sh pairs it with a userspace
    # of the same protocol and boots it under the right QEMU.
    ${ipc32} && proto=7 || proto=8
    printf 'arch=%s\nprotocol=%s\n' "${arch}" "${proto}" > "${dest}/variant"

    # A non-native guest needs its own busybox; Buildroot already has a
    # matching toolchain here, so take it from the same output tree.
    if [ "${arch}" != "x86_64" ]; then
        if br_make O="${o}" busybox >>"${o}.build.log" 2>&1 \
           && [ -x "${o}/target/bin/busybox" ]; then
            cp "${o}/target/bin/busybox" "${dest}/busybox"
        else
            echo "  WARN  ${label}: no ${arch} busybox built — run-qemu-test.sh will skip this variant"
        fi
    fi

    echo "  OK    ${label}: ${dest}/bzImage (${arch}, protocol ${proto})"
    built=$((built + 1))
done

echo ""
echo "[buildroot] built ${built} kernel(s) into ${OUT}/"
[ "${built}" -gt 0 ] || die "no kernels built"
echo "Next: ./tests/qemu/run-qemu-test.sh"
