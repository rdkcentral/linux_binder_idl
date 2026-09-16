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

# Overridable so a caller can build into its own workspace instead of the repo
# tree, which is what a test needs to be isolated and repeatable.
#
# Deliberately NOT the same names build-linux-binder-aidl.sh uses. That script
# invokes this one, so a caller who set BUILD_DIR/OUT_DIR to isolate a TARGET
# build would have the host build inherit them and the two would share a tree -
# host and target artifacts in one directory, with the target run reconfiguring
# the host cache.
BUILD_DIR="${HOST_BUILD_DIR:-${ROOT_DIR}/build-host}"
OUT_DIR="${HOST_OUT_DIR:-${ROOT_DIR}/out/host}"
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
  echo "==> Cleaning build artifacts..."
  # Clean what this invocation would WRITE, which is BUILD_DIR and OUT_DIR
  # whether or not HOST_BUILD_DIR / HOST_OUT_DIR redirected them. Cleaning
  # ${ROOT_DIR}/out unconditionally did both halves of this wrong: it left the
  # overridden directory stale, so the isolated workspace a caller asked for was
  # never cleaned, and it deleted the repository's own out/ — including the
  # TARGET build's output — which the caller had deliberately steered away from.
  _cleaned=""
  clean_dir() {
    case " ${_cleaned} " in *" $1 "*) return ;; esac
    _cleaned="${_cleaned} $1"
    rm -rf "$1" 2>/dev/null || true
    echo "    Cleaned: $1"
  }

  clean_dir "${BUILD_DIR}"
  clean_dir "${OUT_DIR}"

  # The repository's own trees, only when nothing redirected this run away from
  # them. An isolated workspace must not take the shared ones with it.
  if [ -z "${HOST_BUILD_DIR:-}" ] && [ -z "${HOST_OUT_DIR:-}" ]; then
    clean_dir "${ROOT_DIR}/out"
    clean_dir "${ROOT_DIR}/build-host"
    clean_dir "${ROOT_DIR}/build-target"
    clean_dir "${ROOT_DIR}/android"
  else
    echo "    Kept: ${ROOT_DIR}/{out,build-host,build-target,android} — HOST_BUILD_DIR/HOST_OUT_DIR redirected this run"
  fi
  echo "✅ Clean finished"
  exit 0
fi

mkdir -p "${BUILD_DIR}"
mkdir -p "${OUT_DIR}/bin"

echo "==> Configuring CMake for host AIDL tools..."

# Ensure the system m4 is used, not a Yocto toolchain m4.
# Some Yocto SDKs ship m4 < 1.4.12 on PATH (and export M4=... pointing
# at it) which lacks the --gnu flag required by bison 3.x. Export M4
# explicitly to the system binary when we can find one.
# Regression coverage: tests/test_yocto_m4_regression.sh (gh #30).
SYSTEM_M4="$(command -v m4 2>/dev/null || true)"
if [ -x "/usr/bin/m4" ]; then
  SYSTEM_M4="/usr/bin/m4"
fi
if [ -z "${SYSTEM_M4}" ]; then
  echo "WARNING: could not find m4; bison may fail. Install with: sudo apt install m4"
else
  export M4="${SYSTEM_M4}"
  echo "Using m4:        ${M4}"
fi

# NOTE on bison: CMakeLists.txt hard-sets BISON_EXECUTABLE to the
# vendored android/build-tools bison via a plain set() (no CACHE),
# which would override any -DBISON_EXECUTABLE passed here. The M4
# export above is sufficient: the vendored bison reads M4 at runtime.

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
