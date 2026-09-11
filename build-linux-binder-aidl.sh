#!/usr/bin/env bash

#/**
# * Copyright 2024 Comcast Cable Communications Management, LLC
# *
# * Licensed under the Apache License, Version 2.0 (the "License");
# * you may not use this file except in compliance with the License.
# * You may obtain a copy of the License at
# *
# *     http://www.apache.org/licenses/LICENSE-2.0
# *
# * Unless required by applicable law or agreed to in writing, software
# * distributed under the License is distributed on an "AS IS" BASIS,
# * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# * See the License for the specific language governing permissions and
# * limitations under the License.
# *
# * SPDX-License-Identifier: Apache-2.0
# */

set -euo pipefail

# -------------------------------------------------------------------
# build-linux-binder-aidl.sh
#
# Builds the Android Binder libraries and servicemanager for the TARGET.
# These run on the embedded device (typically ARM).
#
# Output: out/target/
#   - lib/*.so (libbinder.so, liblog.so, libbase.so, etc.)
#   - bin/servicemanager
#   - include/ (binder headers)
#
# Build Variables:
#   CC, CXX        - Target cross-compiler (e.g., arm-linux-gnueabihf-gcc)
#                    If NOT set: Uses system default (gcc/g++ from build-essential)
#   CFLAGS         - C compiler flags (e.g., sysroot, target-specific flags)
#   CXXFLAGS       - C++ compiler flags
#   LDFLAGS        - Linker flags
#   BUILD_TYPE     - Debug or Release (default: Release)
#   TARGET_LIB32_VERSION - Declare a 32-bit target (default: follows the toolchain)
#   BINDER_IPC_32BIT - Binder wire protocol: ON = 7, OFF = 8. Must match the
#                    target kernel's CONFIG_ANDROID_BINDER_IPC_32BIT
#                    (default: follows the toolchain)
#   BUILD_DIR      - CMake build tree (default: build-target)
#   OUT_DIR        - Staging tree for libs/bin/include (default: out/target)
#
# Options:
#   clean          - Remove all build artifacts and source directories (android/, build-*, out/)
#   no-host-aidl   - Skip building the host AIDL generator tool
#
# Native build (uses system GCC from build-essential):
#   ./build-linux-binder-aidl.sh
#
# Cross-compile (Yocto-style with sysroot):
#   export CC=arm-linux-gnueabihf-gcc
#   export CXX=arm-linux-gnueabihf-g++
#   export CFLAGS="--sysroot=/path/to/sysroot -march=armv7-a"
#   export CXXFLAGS="--sysroot=/path/to/sysroot -march=armv7-a"
#   export LDFLAGS="--sysroot=/path/to/sysroot"
#   export TARGET_LIB32_VERSION=ON
#   ./build-linux-binder-aidl.sh
#
# Note: This builds for the TARGET architecture.
#       When CC/CXX are NOT set: CMake auto-detects system compiler (native build)
#       When CC/CXX ARE set: Uses specified cross-compiler (Yocto/embedded build)
# -------------------------------------------------------------------

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="${SCRIPT_DIR}"

# Overridable so a caller can stage two configurations side by side without
# them colliding in one reused CMake cache — the QEMU matrix needs a protocol-7
# and a protocol-8 SDK at the same time.
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build-target}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out/target}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
# Left empty when the caller did not state one; resolved from the toolchain
# below, once CC/CFLAGS have been worked out.
TARGET_LIB32="${TARGET_LIB32_VERSION:-}"
CLEAN_BUILD=false
FORCE_BUILD=false
BUILD_HOST_AIDL_TOOL=true

# Cross-compilation handling:
#
# Yocto/OE SDK environment-setup scripts embed arch and sysroot flags into
# CC/CXX (e.g., CC="arm-oe-linux-gnueabi-gcc -march=armv7ve --sysroot=...").
# The OE SDK's cmake uses OEToolchainConfig.cmake which reads CFLAGS/CXXFLAGS
# from the environment but ignores the flags embedded in CC. This causes
# arch flags like -mfloat-abi=hard to be lost, breaking cross-compilation.
#
# Fix: extract the embedded flags from CC/CXX and prepend them to CFLAGS/
# CXXFLAGS so the OE toolchain picks them up. Also split CC/CXX to just the
# compiler binary for non-OE builds where we pass -DCMAKE_C_COMPILER.
TARGET_CC_FULL="${CC:-}"
TARGET_CXX_FULL="${CXX:-}"
TARGET_CC=""
TARGET_CXX=""
TARGET_CC_EXTRA=""
TARGET_CXX_EXTRA=""
TARGET_LDFLAGS="${LDFLAGS:-}"

# Split compiler binary (first word) from embedded flags (remaining words)
if [ -n "${TARGET_CC_FULL}" ]; then
  read -ra _CC_PARTS <<< "${TARGET_CC_FULL}"
  TARGET_CC="${_CC_PARTS[0]}"
  TARGET_CC_EXTRA="${_CC_PARTS[*]:1}"
fi

if [ -n "${TARGET_CXX_FULL}" ]; then
  read -ra _CXX_PARTS <<< "${TARGET_CXX_FULL}"
  TARGET_CXX="${_CXX_PARTS[0]}"
  TARGET_CXX_EXTRA="${_CXX_PARTS[*]:1}"
fi

# Prepend arch flags extracted from CC/CXX into CFLAGS/CXXFLAGS environment.
# This ensures the OE toolchain file (which reads CFLAGS/CXXFLAGS) gets the
# arch flags, and also works for non-OE cmake builds via -DCMAKE_C_FLAGS.
if [ -n "${TARGET_CC_EXTRA}" ]; then
  export CFLAGS="${TARGET_CC_EXTRA} ${CFLAGS:-}"
fi
if [ -n "${TARGET_CXX_EXTRA}" ]; then
  export CXXFLAGS="${TARGET_CXX_EXTRA} ${CXXFLAGS:-}"
fi
TARGET_CFLAGS="${CFLAGS:-}"
TARGET_CXXFLAGS="${CXXFLAGS:-}"

# Pointer size of the TARGET toolchain. Ask the configured compiler rather than
# the host: with a cross toolchain in CC the two differ, and it is the target
# that matters.
# set -e / pipefail are active, so a compiler that cannot run must fall through
# rather than abort the build.
TARGET_PTR_SIZE="$(${TARGET_CC:-cc} ${TARGET_CFLAGS} -dM -E -x c /dev/null 2>/dev/null \
                   | sed -n 's/^#define __SIZEOF_POINTER__ //p' || true)"

# An empty probe means this script cannot tell 32-bit from 64-bit. Do NOT guess:
# guessing 32-bit selects protocol 7, which the toolchain guard then rejects on
# any 64-bit compiler, turning an unreadable compiler into an unexplained
# configure abort. Defer to CMake instead — CMAKE_SIZEOF_VOID_P comes from its
# own compiler detection and is authoritative — and clear both cache entries so
# a value from an earlier run in the reused build dir cannot stick (#46/#47).
PTR_SIZE_KNOWN=1
if [ -z "${TARGET_PTR_SIZE}" ]; then
  PTR_SIZE_KNOWN=0
  echo "WARNING: could not probe the pointer size of '${TARGET_CC:-cc}'."
  echo "         Leaving target bitness and wire protocol to CMake's own"
  echo "         toolchain detection. Set TARGET_LIB32_VERSION / BINDER_IPC_32BIT"
  echo "         explicitly to override."
fi

# Declared target bitness, when the caller did not state one and the probe
# worked. With no probe the -D is omitted entirely so CMake's default applies.
if [ -z "${TARGET_LIB32}" ] && [ "${PTR_SIZE_KNOWN}" = "1" ]; then
  case "${TARGET_PTR_SIZE}" in
    8) TARGET_LIB32=OFF ;;
    *) TARGET_LIB32=ON  ;;
  esac
fi

# A caller-declared bitness that the toolchain contradicts is unbuildable, and
# the failure otherwise surfaces as a confusing protocol guard further down.
if [ "${PTR_SIZE_KNOWN}" = "1" ] && [ "${TARGET_LIB32}" = "OFF" ] \
   && [ "${TARGET_PTR_SIZE}" = "4" ] && [ -z "${BINDER_IPC_32BIT:-}" ]; then
  echo "ERROR: TARGET_LIB32_VERSION=OFF declares a 64-bit target, but '${TARGET_CC:-cc}'" >&2
  echo "       is a 32-bit toolchain. For a 32-bit protocol-8 library (the mixed" >&2
  echo "       32-bit-MW configuration) declare the bitness the compiler actually" >&2
  echo "       has and select the protocol directly:" >&2
  echo "           TARGET_LIB32_VERSION=ON BINDER_IPC_32BIT=OFF $0" >&2
  exit 1
fi

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --clean|clean)
      CLEAN_BUILD=true
      ;;
    --force|force)
      FORCE_BUILD=true
      ;;
    --help|-h|help)
      echo "Usage: $0 [clean] [force] [no-host-aidl] [help]"
      echo "  clean          Remove all build artifacts and source directories (android/, build-*, out/)"
      echo "  force          Force rebuild of binder libraries (wipes build dir, keeps android sources)"
      echo "  no-host-aidl   Skip building the host AIDL generator tool"
      echo "  help           Show this help message"
      exit 0
      ;;
    --no-host-aidl|no-host-aidl)
      BUILD_HOST_AIDL_TOOL=false
      ;;
    *)
      echo "Unknown option: $arg"
      echo "Use 'help' for usage information"
      exit 1
      ;;
  esac
done

echo "=========================================="
echo "  Building Binder Target Libraries"
echo "=========================================="
echo "Root dir:        ${ROOT_DIR}"
echo "Build dir:       ${BUILD_DIR}"
echo "Output dir:      ${OUT_DIR}"
echo "Build type:      ${BUILD_TYPE}"
echo "Target 32-bit:   ${TARGET_LIB32}"
echo "Target CC:       ${TARGET_CC:-system default}"
echo "Target CXX:      ${TARGET_CXX:-system default}"
echo "Target CFLAGS:   ${TARGET_CFLAGS:-none}"
echo "Target CXXFLAGS: ${TARGET_CXXFLAGS:-none}"
echo "Target LDFLAGS:  ${TARGET_LDFLAGS:-none}"
echo "Clean build:     ${CLEAN_BUILD}"
echo "Force build:     ${FORCE_BUILD}"
echo "Build host AIDL: ${BUILD_HOST_AIDL_TOOL}"
echo "=========================================="

if [ "$CLEAN_BUILD" = true ]; then
  echo "==> Cleaning all build artifacts and source directories..."
  rm -rf "${BUILD_DIR}" 2>/dev/null || true
  echo "    Cleaned: ${BUILD_DIR}"
  rm -rf "${ROOT_DIR}/build-target-cmake" 2>/dev/null || true
  echo "    Cleaned: ${ROOT_DIR}/build-target-cmake"
  rm -rf "${ROOT_DIR}/CMakeFiles" 2>/dev/null || true
  echo "    Cleaned: ${ROOT_DIR}/CMakeFiles"
  rm -rf "${ROOT_DIR}/out" 2>/dev/null || true
  echo "    Cleaned: ${ROOT_DIR}/out"
  rm -rf "${ROOT_DIR}/build-host" 2>/dev/null || true
  echo "    Cleaned: ${ROOT_DIR}/build-host"
  rm -rf "${ROOT_DIR}/build-target" 2>/dev/null || true
  echo "    Cleaned: ${ROOT_DIR}/build-target"
  rm -rf "${ROOT_DIR}/android" 2>/dev/null || true
  echo "    Cleaned: ${ROOT_DIR}/android"
  echo "✅ Complete clean finished"
  exit 0
fi

if [ "$FORCE_BUILD" = true ]; then
  echo "==> Force rebuild: removing binder build directory (android sources kept)..."
  rm -rf "${BUILD_DIR}" 2>/dev/null || true
  echo "    Cleaned: ${BUILD_DIR}"
fi

# Remove stale in-source CMake artifacts from legacy builds.
rm -rf "${ROOT_DIR}/build-target-cmake" 2>/dev/null || true
rm -rf "${ROOT_DIR}/CMakeFiles" 2>/dev/null || true

# Build host AIDL tool first (needed for generating binder AIDL stubs/proxies)
if [ "$BUILD_HOST_AIDL_TOOL" = true ]; then
  echo "==> Building host AIDL tools..."
  BUILD_TYPE="${BUILD_TYPE}" "${ROOT_DIR}/build-aidl-generator-tool.sh"
fi

mkdir -p "${BUILD_DIR}"
mkdir -p "${OUT_DIR}/lib" "${OUT_DIR}/bin" "${OUT_DIR}/include"

echo "==> Configuring CMake for target binder libraries..."

# Prepare CMake arguments
CMAKE_ARGS=(
  -S "${ROOT_DIR}"
  -B "${BUILD_DIR}"
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}"
  -DBUILD_HOST_AIDL=OFF
)
if [ -n "${TARGET_LIB32}" ]; then
  CMAKE_ARGS+=(-DTARGET_LIB32_VERSION="${TARGET_LIB32}")
else
  # No probe and no caller value: drop any cached entry so CMake's own
  # toolchain-derived default applies instead of a stale one.
  CMAKE_ARGS+=(-UTARGET_LIB32_VERSION)
fi

# Binder wire protocol, decoupled from compile bitness (#42, #72). Pass an
# explicit BOOL when the caller states one, so a value cached from an earlier
# run in the reused build-target dir cannot silently stick (a prior
# BINDER_IPC_32BIT=ON run leaving the cache at protocol 7). Otherwise clear the
# cache entry and let CMakeLists.txt apply the default, which is protocol 8 on
# every toolchain.
#
# This deliberately does NOT derive. It used to mirror CMake's toolchain-derived
# default here, and one rule written in two places is how the two drift apart:
# when the default moved to protocol 8, this copy went on passing ON for a
# 32-bit toolchain and quietly overrode it.
if [ -n "${BINDER_IPC_32BIT:-}" ]; then
  CMAKE_ARGS+=(-DBINDER_IPC_32BIT:BOOL="${BINDER_IPC_32BIT}")
else
  CMAKE_ARGS+=(-UBINDER_IPC_32BIT)
fi

# When OE SDK cmake is used, the OEToolchainConfig.cmake handles compiler,
# sysroot, and flags from the environment. We've already prepended the arch
# flags from CC/CXX into CFLAGS/CXXFLAGS, so the toolchain picks them up.
#
# For non-OE builds (no CMAKE_TOOLCHAIN_FILE), pass explicit cmake -D args.
if [ -z "${CMAKE_TOOLCHAIN_FILE:-}" ]; then
  if [ -n "${TARGET_CC}" ]; then
    CMAKE_ARGS+=(-DCMAKE_C_COMPILER="${TARGET_CC}")
  fi
  if [ -n "${TARGET_CXX}" ]; then
    CMAKE_ARGS+=(-DCMAKE_CXX_COMPILER="${TARGET_CXX}")
  fi
  if [ -n "${TARGET_CFLAGS}" ]; then
    CMAKE_ARGS+=(-DCMAKE_C_FLAGS="${TARGET_CFLAGS}")
  fi
  if [ -n "${TARGET_CXXFLAGS}" ]; then
    CMAKE_ARGS+=(-DCMAKE_CXX_FLAGS="${TARGET_CXXFLAGS}")
  fi
  if [ -n "${TARGET_LDFLAGS}" ]; then
    CMAKE_ARGS+=(-DCMAKE_EXE_LINKER_FLAGS="${TARGET_LDFLAGS}")
    CMAKE_ARGS+=(-DCMAKE_SHARED_LINKER_FLAGS="${TARGET_LDFLAGS}")
  fi
fi

# Run CMake configuration
cmake "${CMAKE_ARGS[@]}"

echo "==> Building target binder libraries..."
cmake --build "${BUILD_DIR}" --target all -- -j"$(nproc)"

echo "==> Installing to ${OUT_DIR}..."
cp "${BUILD_DIR}"/*.so "${OUT_DIR}/lib/" 2>/dev/null || true
cp "${BUILD_DIR}"/servicemanager "${OUT_DIR}/bin/" 2>/dev/null || true

# Install headers
cp -r "${ROOT_DIR}/binder_aidl_gen/include/"* "${OUT_DIR}/include/" 2>/dev/null || true
cp -r "${ROOT_DIR}/android/native/libs/binder/include/binder" "${OUT_DIR}/include/" 2>/dev/null || true
cp -r "${ROOT_DIR}/android/native/libs/binder/ndk/include_cpp/"* "${OUT_DIR}/include/" 2>/dev/null || true
cp -r "${ROOT_DIR}/android/libbase/include/"* "${OUT_DIR}/include/" 2>/dev/null || true
cp -r "${ROOT_DIR}/android/core/libutils/include/"* "${OUT_DIR}/include/" 2>/dev/null || true
cp -r "${ROOT_DIR}/android/core/libcutils/include/"* "${OUT_DIR}/include/" 2>/dev/null || true
cp -r "${ROOT_DIR}/android/logging/liblog/include/"* "${OUT_DIR}/include/" 2>/dev/null || true

echo ""
echo "✅ Target binder libraries built successfully"
echo "   Libraries:      ${OUT_DIR}/lib/"
echo "   Servicemanager: ${OUT_DIR}/bin/servicemanager"
echo "   Headers:        ${OUT_DIR}/include/"
