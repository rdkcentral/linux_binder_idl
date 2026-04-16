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
# build-aidl-generator-tool.sh
#
# Builds ONLY the host AIDL compiler tools (aidl, aidl-cpp)
# These run on the build machine to generate code.
#
# Output: out/host/
#   - bin/aidl
#   - bin/aidl-cpp
#
# Build Variables:
#   HOST_CC, HOST_CXX  - Host compiler (default: gcc/g++ for native architecture)
#   BUILD_TYPE         - Debug or Release (default: Release)
#
# Options:
#   --clean        - Remove all build artifacts and source directories (android/, build-*, out/)
#
# Note: This ALWAYS builds for the HOST architecture (build machine).
#       CC/CXX environment variables are IGNORED (may be target cross-compilers).
#       Use HOST_CC/HOST_CXX to override native compilers if needed.
# -------------------------------------------------------------------

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="${SCRIPT_DIR}"

BUILD_DIR="${ROOT_DIR}/build-host"
OUT_DIR="${ROOT_DIR}/out/host"
BUILD_TYPE="${BUILD_TYPE:-Release}"
CLEAN_BUILD=false

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --clean|clean)
      CLEAN_BUILD=true
      ;;
    --help|-h|help)
      echo "Usage: $0 [clean] [help]"
      echo "  clean  Remove all build artifacts and source directories (android/, build-*, out/)"
      echo "  help   Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg"
      echo "Use 'help' for usage information"
      exit 1
      ;;
  esac
done

# Force native x86_64 compilers for host tools
# Host tools MUST run on the build machine, not the target
# Ignore any cross-compilation environment (Yocto CC/CXX)
HOST_CC="${HOST_CC:-gcc}"
HOST_CXX="${HOST_CXX:-g++}"

echo "=========================================="
echo "  Building AIDL Host Tools"
echo "=========================================="
echo "Root dir:        ${ROOT_DIR}"
echo "Build dir:       ${BUILD_DIR}"
echo "Output dir:      ${OUT_DIR}"
echo "Build type:      ${BUILD_TYPE}"
echo "Host CC:         ${HOST_CC}"
echo "Host CXX:        ${HOST_CXX}"
echo "Clean build:     ${CLEAN_BUILD}"
echo "=========================================="

if [ "$CLEAN_BUILD" = true ]; then
  echo "==> Cleaning all build artifacts and source directories..."
  rm -rf "${BUILD_DIR}" 2>/dev/null || true
  echo "    Cleaned: ${BUILD_DIR}"
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

mkdir -p "${BUILD_DIR}"
mkdir -p "${OUT_DIR}/bin"

echo "==> Configuring CMake for host AIDL tools..."

# Force native host build: override any cross-compilation settings.
# In a Yocto/SDK environment, CMAKE_TOOLCHAIN_FILE (OEToolchainConfig.cmake)
# and CFLAGS/CXXFLAGS (with --sysroot for ARM) are set for the TARGET.
# Host tools MUST build natively, so we override these via cmake -D flags
# without modifying the environment variables themselves.
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" \
  -DCMAKE_TOOLCHAIN_FILE="" \
  -DCMAKE_C_COMPILER="${HOST_CC}" \
  -DCMAKE_CXX_COMPILER="${HOST_CXX}" \
  -DCMAKE_C_FLAGS="" \
  -DCMAKE_CXX_FLAGS="" \
  -DCMAKE_EXE_LINKER_FLAGS="" \
  -DCMAKE_SHARED_LINKER_FLAGS="" \
  -DCMAKE_SYSROOT="" \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DBUILD_HOST_AIDL=ON

echo "==> Building host AIDL compiler (and required libraries)..."
cmake --build "${BUILD_DIR}" --target aidl aidl-cpp -- -j"$(nproc)"

echo "==> Installing to ${OUT_DIR}..."
cp "${BUILD_DIR}/aidl" "${BUILD_DIR}/aidl-cpp" "${OUT_DIR}/bin/"

echo ""
echo "✅ Host AIDL tools built successfully"
echo "   Output: ${OUT_DIR}/bin/aidl"
echo "   Output: ${OUT_DIR}/bin/aidl-cpp"
