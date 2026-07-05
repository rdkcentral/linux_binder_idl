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
#   TARGET_LIB32_VERSION - Set to OFF to build 64-bit target (default: ON for 32-bit)
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

BUILD_DIR="${ROOT_DIR}/build-target"
OUT_DIR="${ROOT_DIR}/out/target"
BUILD_TYPE="${BUILD_TYPE:-Release}"
TARGET_LIB32="${TARGET_LIB32_VERSION:-ON}"
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
  -DTARGET_LIB32_VERSION="${TARGET_LIB32}"
)

# Binder wire protocol is decoupled from compile bitness (#42): forward
# BINDER_IPC_32BIT when set so a 32-bit build can select protocol 8
# (BINDER_IPC_32BIT=OFF). Unset -> CMake defaults it to follow the bitness.
if [ -n "${BINDER_IPC_32BIT:-}" ]; then
  CMAKE_ARGS+=(-DBINDER_IPC_32BIT="${BINDER_IPC_32BIT}")
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
