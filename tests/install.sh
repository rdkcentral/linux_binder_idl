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
# Install the prerequisites for the on-demand test harnesses, in particular the
# QEMU binder round-trip test (tests/qemu/).
#
# Two groups:
#   RUN   — to run tests/qemu/run-qemu-test.sh: qemu, busybox, cpio, g++, gzip
#           (timeout/ldd come with coreutils/libc and are normally present).
#   BUILD — to build the kernel matrix with tests/qemu/build-kernels.sh
#           (Buildroot): toolchain + wget/tar/rsync/bc/flex/bison/unzip/ncurses/
#           openssl/elf headers, etc.
#
# Usage:
#   ./tests/install.sh              # install RUN + BUILD prerequisites
#   ./tests/install.sh --minimal    # RUN prerequisites only (bring your own kernels)
#   ./tests/install.sh --dry-run    # print the package list, install nothing
#
# Supports apt / dnf / pacman. Uses sudo when not root.
set -euo pipefail

MINIMAL=false
DRY_RUN=false
for a in "$@"; do
    case "$a" in
        --minimal) MINIMAL=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) sed -n '20,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $a" >&2; exit 2 ;;
    esac
done

# Detect package manager + per-manager package names.
if   command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf     >/dev/null 2>&1; then PM=dnf
elif command -v pacman  >/dev/null 2>&1; then PM=pacman
else echo "ERROR: no supported package manager (apt/dnf/pacman) found." >&2; exit 1; fi

case "${PM}" in
    # Note: the *-multilib / .i686 packages provide the 32-bit (-m32) toolchain
    # for building a 32-bit binder locally on an x86_64 host (real targets use an
    # ARM cross-toolchain instead). Needed for the default TARGET_LIB32 build.
    apt)
        RUN_PKGS=(qemu-system-x86 busybox-static cpio g++ gzip)
        BUILD_PKGS=(build-essential gcc-multilib g++-multilib wget tar rsync bc flex bison
                    unzip file git python3 libncurses-dev libssl-dev libelf-dev)
        INSTALL=(apt-get install -y)
        REFRESH=(apt-get update) ;;
    dnf)
        RUN_PKGS=(qemu-system-x86 busybox cpio gcc-c++ gzip)
        BUILD_PKGS=(make gcc gcc-c++ glibc-devel.i686 libstdc++-devel.i686 wget tar rsync bc
                    flex bison unzip file git python3 ncurses-devel openssl-devel elfutils-libelf-devel)
        INSTALL=(dnf install -y)
        REFRESH=(true) ;;
    pacman)
        RUN_PKGS=(qemu-system-x86 busybox cpio gcc gzip)
        BUILD_PKGS=(base-devel lib32-gcc-libs wget tar rsync bc flex bison unzip file git python ncurses openssl)
        INSTALL=(pacman -S --needed --noconfirm)
        REFRESH=(true) ;;
esac

PKGS=("${RUN_PKGS[@]}")
${MINIMAL} || PKGS+=("${BUILD_PKGS[@]}")

echo "Package manager: ${PM}"
echo "Mode:            $([ "${MINIMAL}" = true ] && echo 'RUN only (--minimal)' || echo 'RUN + BUILD')"
echo "Packages:        ${PKGS[*]}"

if [ "${DRY_RUN}" = true ]; then
    echo "(--dry-run: nothing installed)"
    exit 0
fi

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

[ "${REFRESH[0]}" = true ] || ${SUDO} "${REFRESH[@]}"
${SUDO} "${INSTALL[@]}" "${PKGS[@]}"

echo ""
echo "✓ prerequisites installed. Next:"
${MINIMAL} && echo "  ./tests/qemu/run-qemu-test.sh --kernel <bzImage>" \
           || echo "  ./tests/qemu/build-kernels.sh && ./tests/qemu/run-qemu-test.sh"
