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
# Three groups:
#   RUN   — to run tests/qemu/run-qemu-test.sh: qemu, busybox, cpio, gzip, and
#           the compiler + cmake/make it builds the binder SDK with
#           (timeout/ldd come with coreutils/libc and are normally present).
#   BUILD — to build the kernel matrix with tests/qemu/build-kernels.sh
#           (Buildroot): toolchain + wget/tar/rsync/bc/flex/bison/unzip/ncurses/
#           openssl/elf headers, etc.
#   32BIT — opt-in, --with-32bit: the 32-bit libc/libstdc++ and i386 kernel
#           headers that the protocol-7 (i386) guest userspace is compiled with.
#           Without it the runner skips that variant and tests protocol 8 only.
#
# Note: on Debian/Ubuntu this deliberately installs the component packages
# rather than the gcc-multilib metapackage. gcc-multilib CONFLICTS with the ARM
# cross compilers (gcc-arm-linux-gnueabihf) — apt removes one to install the
# other — while libc6-dev-i386/lib32stdc++/linux-libc-dev:i386 supply the same
# -m32 capability and coexist with them. ARM cross-compilation is how real
# targets are built, so a test prerequisite must not displace it.
#
# Usage:
#   ./tests/install.sh                # install RUN + BUILD prerequisites
#   ./tests/install.sh --minimal      # RUN prerequisites only (bring your own kernels)
#   ./tests/install.sh --with-32bit   # also install the protocol-7 toolchain (see WARNING)
#   ./tests/install.sh --dry-run      # print the package list, install nothing
#
# Supports apt / dnf / pacman. Uses sudo when not root.
set -euo pipefail

MINIMAL=false
DRY_RUN=false
WITH_32BIT=false
for a in "$@"; do
    case "$a" in
        --minimal)    MINIMAL=true ;;
        --dry-run)    DRY_RUN=true ;;
        --with-32bit) WITH_32BIT=true ;;
        -h|--help) sed -n '20,41p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $a" >&2; exit 2 ;;
    esac
done

# Detect package manager + per-manager package names.
if   command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf     >/dev/null 2>&1; then PM=dnf
elif command -v pacman  >/dev/null 2>&1; then PM=pacman
else echo "ERROR: no supported package manager (apt/dnf/pacman) found." >&2; exit 1; fi

case "${PM}" in
    # M32_PKGS is the opt-in 32-bit toolchain (see the note above). The 32-bit
    # libc alone is not enough — the i386 *kernel* headers are a separate
    # package, and without them a -m32 compile fails on asm/errno.h.
    apt)
        RUN_PKGS=(qemu-system-x86 busybox-static cpio g++ gzip cmake make)
        BUILD_PKGS=(build-essential wget tar rsync bc flex bison
                    unzip file git python3 libncurses-dev libssl-dev libelf-dev)
        M32_PKGS=(libc6-dev-i386 lib32stdc++-13-dev linux-libc-dev:i386)
        INSTALL=(apt-get install -y)
        REFRESH=(apt-get update) ;;
    dnf)
        RUN_PKGS=(qemu-system-x86 busybox cpio gcc-c++ gzip cmake make)
        BUILD_PKGS=(make gcc gcc-c++ wget tar rsync bc
                    flex bison unzip file git python3 ncurses-devel openssl-devel elfutils-libelf-devel)
        M32_PKGS=(glibc-devel.i686 libstdc++-devel.i686)
        INSTALL=(dnf install -y)
        REFRESH=(true) ;;
    pacman)
        RUN_PKGS=(qemu-system-x86 busybox cpio gcc gzip cmake make)
        BUILD_PKGS=(base-devel wget tar rsync bc flex bison unzip file git python ncurses openssl)
        M32_PKGS=(lib32-gcc-libs)
        INSTALL=(pacman -S --needed --noconfirm)
        REFRESH=(true) ;;
esac

PKGS=("${RUN_PKGS[@]}")
${MINIMAL} || PKGS+=("${BUILD_PKGS[@]}")
${WITH_32BIT} && PKGS+=("${M32_PKGS[@]}")

echo "Package manager: ${PM}"
echo "Mode:            $([ "${MINIMAL}" = true ] && echo 'RUN only (--minimal)' || echo 'RUN + BUILD')$(${WITH_32BIT} && echo ' + 32BIT')"
echo "Packages:        ${PKGS[*]}"

if ${WITH_32BIT} && [ "${PM}" = apt ]; then
    echo ""
    echo "Note: installing the 32-bit component packages, not gcc-multilib —"
    echo "      the metapackage would displace gcc-arm-linux-gnueabihf."
fi

if [ "${DRY_RUN}" = true ]; then
    echo "(--dry-run: nothing installed)"
    exit 0
fi

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

# linux-libc-dev:i386 lives in the i386 foreign architecture, which has to be
# enabled before the refresh or apt won't see the package at all.
if ${WITH_32BIT} && [ "${PM}" = apt ]; then
    ${SUDO} dpkg --add-architecture i386
fi

[ "${REFRESH[0]}" = true ] || ${SUDO} "${REFRESH[@]}"
${SUDO} "${INSTALL[@]}" "${PKGS[@]}"

echo ""
echo "✓ prerequisites installed. Next:"
${MINIMAL} && echo "  ./tests/qemu/run-qemu-test.sh --kernel <bzImage>" \
           || echo "  ./tests/qemu/build-kernels.sh && ./tests/qemu/run-qemu-test.sh"
