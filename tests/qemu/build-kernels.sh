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
# a bootable x86_64 bzImage with the Binder driver enabled (binder.fragment),
# and drops it at tests/qemu/kernels/<version>/bzImage for run-qemu-test.sh.
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
# range (4.9 floor → 5.16). IPC32=1 marks the legacy protocol-7 (all-32-bit)
# variant, which also merges binder-ipc32.fragment.
VERSIONS="${VERSIONS:-4.9.337 5.4.290 5.10.205 5.15.148 5.16.20}"
BR_VERSION="${BR_VERSION:-2024.02.9}"

die()  { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

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
    case "${spec}" in *:ipc32) ipc32=true ;; esac
    label="${ver}"; ${ipc32} && label="${ver}-ipc32"
    o="${BUILDROOT}/output-${label}"
    dest="${OUT}/${label}"

    echo ""
    echo "=== kernel ${label} ==="
    # Minimal QEMU x86_64 target, custom kernel version, our binder fragment.
    frags="${FRAGMENT}"; ${ipc32} && frags="${FRAGMENT} ${IPC32_FRAGMENT}"
    cat > "${o}.config" <<EOF
BR2_x86_64=y
BR2_TOOLCHAIN_BUILDROOT_CXX=y
BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_CUSTOM_VERSION=y
BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="${ver}"
BR2_LINUX_KERNEL_DEFCONFIG="x86_64"
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="${frags}"
BR2_LINUX_KERNEL_BZIMAGE=y
EOF
    if ! make -C "${BUILDROOT}" O="${o}" defconfig BR2_DEFCONFIG="${o}.config" >/dev/null 2>&1; then
        echo "  FAIL  ${label}: buildroot defconfig failed"; continue
    fi
    if ! make -C "${BUILDROOT}" O="${o}" linux >"${o}.build.log" 2>&1; then
        echo "  FAIL  ${label}: kernel build failed — see ${o}.build.log"; continue
    fi
    img="$(find "${o}/images" -name 'bzImage' -type f 2>/dev/null | head -1)"
    if [ -z "${img}" ]; then echo "  FAIL  ${label}: no bzImage produced"; continue; fi
    mkdir -p "${dest}"; cp "${img}" "${dest}/bzImage"
    echo "  OK    ${label}: ${dest}/bzImage"
    built=$((built + 1))
done

echo ""
echo "[buildroot] built ${built} kernel(s) into ${OUT}/"
[ "${built}" -gt 0 ] || die "no kernels built"
echo "Next: ./tests/qemu/run-qemu-test.sh"
