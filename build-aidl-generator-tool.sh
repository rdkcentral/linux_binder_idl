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
  echo "==> Cleaning all build artifacts and source directories..."
  # `clean` exists so a user can get back to a COMPLETELY clean environment, so
  # it takes the repository trees unconditionally - including android/, the
  # unpacked AOSP sources. Nothing here is conditional on how the build was
  # directed: a clean that left something behind because of an environment
  # variable would not be the thing this command is for. downloads/ stays: it
  # holds the AOSP source tarball, an input checked against its sha256 on every
  # use, not build state.
  #
  # BUILD_DIR and OUT_DIR are cleaned as well as, not instead of, those trees.
  # They are the same paths by default; when HOST_BUILD_DIR / HOST_OUT_DIR have
  # redirected them they are extra ones, and leaving a redirected directory
  # behind would be exactly the leftover state this command promises to remove.
  _cleaned=""
  clean_dir() {
    [ -n "$1" ] || return
    case " ${_cleaned} " in *" $1 "*) return ;; esac   # same path twice
    _cleaned="${_cleaned} $1"
    # Report only what was actually there. The default OUT_DIR sits inside out/,
    # so it is already gone by the time this reaches it, and announcing a second
    # removal of a path that no longer exists reads like the clean ran twice.
    if [ -e "$1" ]; then
      rm -rf "$1" 2>/dev/null || true
      echo "    Cleaned: $1"
    fi
  }

  clean_dir "${ROOT_DIR}/out"
  clean_dir "${ROOT_DIR}/build-host"
  clean_dir "${ROOT_DIR}/build-target"
  clean_dir "${ROOT_DIR}/android"
  clean_dir "${BUILD_DIR}"
  clean_dir "${OUT_DIR}"
  echo "✅ Complete clean finished"
  exit 0
fi

# AOSP sources: unpack the tarball into android/ and apply patches/, unless it
# is already current. The tarball comes from downloads/, from AOSP_SOURCE_URI,
# or is generated from aosp/manifest - see ./aosp-source.sh help.
"${ROOT_DIR}/aosp-source.sh" provision

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

# flex and bison are the build host's own (find_package in CMakeLists.txt);
# bison reads M4 at runtime, which is why the export above matters.

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
