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

# ==============================================================================
# build-binder-example.sh
#
# Build example client/server code that links against the target Binder SDK.
#
# Behaviour:
#   - Always calls build-linux-binder-aidl.sh first (stamps make this cheap).
#   - Uses its own build directory: ${BUILD_DIR}/examples
#   - Runs CMake and builds the example targets.
#
# Flags:
#   --force   Force rebuild of examples (and pass --force to Binder SDK build).
#   --clean   Remove examples build dir (and pass --clean to Binder SDK build).
#   --help    Show usage.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/setup-env.sh"

# TARGET_SDK_DIR already set by setup-env.sh to ${OUT_DIR}/target
EXAMPLE_BUILD_DIR="${OUT_DIR}/build/examples"

FORCE=0
CLEAN=0
CLEAN_AIDL=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [force] [clean] [clean-aidl] [help]

Build binder example binaries that link against the target Binder SDK.

Options:
  force         Force rebuild of Binder SDK and examples.
  clean         Remove examples build directory (and clean Binder SDK as well).
  clean-aidl    Remove generated AIDL C++ files (requires regeneration).
  help          Show this help and exit.

Environment:
  WORK_DIR       Root of repo.
  OUT_DIR        Root for build artifacts (default: ${WORK_DIR}/out).
  TARGET_SDK_DIR Target Binder SDK root (default: ${OUT_DIR}/target).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --force|force) FORCE=1 ;;
    --clean|clean) CLEAN=1 ;;
    --clean-aidl|clean-aidl) CLEAN_AIDL=1 ;;
    --help|-h|help)  usage; exit 0 ;;
    *) LOGE "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

LOGI "==== build-binder-example.sh ===="
LOGI "WORK_DIR        = ${WORK_DIR}"
LOGI "OUT_DIR         = ${OUT_DIR}"
LOGI "TARGET_SDK_DIR  = ${TARGET_SDK_DIR}"
LOGI "EXAMPLE_BUILD   = ${EXAMPLE_BUILD_DIR}"
LOGI "FORCE=${FORCE} CLEAN=${CLEAN} CLEAN_AIDL=${CLEAN_AIDL}"

# ------------------------------------------------------------------------------
# Handle clean-only modes (exit after cleanup)
# ------------------------------------------------------------------------------
if [ "${CLEAN_AIDL}" -eq 1 ]; then
  FWMANAGER_GEN_DIR="${SCRIPT_DIR}/example/stable/generated/FWManager"
  LOGW "Removing generated AIDL C++ files..."
  rm -rf "${FWMANAGER_GEN_DIR}"
  mkdir -p "${FWMANAGER_GEN_DIR}"
  LOGI "✓ Generated AIDL files cleaned"
  exit 0
fi

if [ "${CLEAN}" -eq 1 ]; then
  LOGW "Cleaning binder example build directory..."
  rm -rf "${EXAMPLE_BUILD_DIR}"
  LOGI "✓ Example build directory cleaned"

  # Also clean SDK if requested
  LOGI "Cleaning Binder SDK..."
  "${SCRIPT_DIR}/build-linux-binder-aidl.sh" --clean
  LOGI "✓ Binder SDK cleaned"
  exit 0
fi

# ------------------------------------------------------------------------------
# 1) Ensure Binder SDK is built
# ------------------------------------------------------------------------------
BUILD_ARGS=()
[ "${FORCE}" -eq 1 ] && BUILD_ARGS+=("--force")

LOGI "Building Binder SDK..."
"${SCRIPT_DIR}/build-linux-binder-aidl.sh" "${BUILD_ARGS[@]}"

# ------------------------------------------------------------------------------
# 2) Build AIDL generator tool (host compiler)
# ------------------------------------------------------------------------------
LOGI "Building AIDL generator tool..."
"${SCRIPT_DIR}/build-aidl-generator-tool.sh"

# ------------------------------------------------------------------------------
# 3) Generate C++ code from AIDL files
# ------------------------------------------------------------------------------
FWMANAGER_GEN_DIR="${SCRIPT_DIR}/example/stable/generated/FWManager"
if [ ! -d "$FWMANAGER_GEN_DIR" ] || [ -z "$(ls -A "$FWMANAGER_GEN_DIR" 2>/dev/null)" ]; then
  LOGW "⚠️  Generated AIDL C++ files are missing or empty!"
  LOGW "    These files are normally pre-committed to git in:"
  LOGW "    ${FWMANAGER_GEN_DIR}"
  LOGW ""
  LOGW "    Regenerating will modify tracked files in the repository."
  LOGW ""

  if [ -t 0 ]; then  # Check if stdin is a terminal (interactive)
    read -r -p "    Do you want to generate C++ code from .aidl files? [y/N] " response
    case "$response" in
      [yY][eE][sS]|[yY])
        LOGI "Proceeding with C++ code generation..."
        ;;
      *)
        LOGE "Aborting. Please restore generated files or use --force to regenerate."
        exit 1
        ;;
    esac
  else
    LOGE "Non-interactive mode: cannot prompt for confirmation"
    LOGE "Use --clean-aidl explicitly to regenerate tracked files"
    exit 1
  fi

  # Set AIDL_BIN for the generate script (host tools, not target)
  export AIDL_BIN="${OUT_DIR}/host/bin/aidl"

  if [ ! -x "$AIDL_BIN" ]; then
    LOGE "AIDL compiler not found at $AIDL_BIN"
    LOGE "Please build AIDL generator tool first"
    exit 1
  fi

  "${SCRIPT_DIR}/example/generate_cpp.sh"
  LOGI "✓ C++ code generation complete"
  LOGW "⚠️  Remember to review and commit changes to generated files"
else
  LOGI "Using pre-generated AIDL C++ files from ${FWMANAGER_GEN_DIR}"
fi

# ------------------------------------------------------------------------------
# 4) Configure & build examples
# ------------------------------------------------------------------------------
[ "${FORCE}" -eq 1 ] && rm -rf "${EXAMPLE_BUILD_DIR}"
mkdir -p "${EXAMPLE_BUILD_DIR}"
cd "${EXAMPLE_BUILD_DIR}"

# ------------------------------------------------------------------------------
# 5) Configure & build examples
# ------------------------------------------------------------------------------
LOGI "Configuring CMake for binder examples..."
"${CMAKE}" \
  -DCMAKE_INSTALL_PREFIX="${TARGET_SDK_DIR}" \
  -DBUILD_ENV_HOST=ON \
  "${WORK_DIR}/example"

LOGI "Building binder example binaries..."
make -j"$(nproc)"

LOGI "Installing binder examples to ${TARGET_SDK_DIR}..."
make install

LOGI "==== Binder examples build complete ===="
LOGI "Binaries installed to:"
LOGI "  ${TARGET_SDK_DIR}/bin/FWManagerService"
LOGI "  ${TARGET_SDK_DIR}/bin/FWManagerClient"
LOGI "  ${TARGET_SDK_DIR}/lib/libfwmanager.so"
