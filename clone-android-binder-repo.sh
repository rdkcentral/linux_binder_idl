#!/usr/bin/env bash

#/**
# * Copyright 2024 Comcast Cable Communications Management, LLC
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

# ==============================================================================
# clone-android-binder-repo.sh
#
# Clones Android AOSP source repositories required for Linux Binder.
# This script must be run before building the binder framework or AIDL tools.
#
# Clones the following repositories:
#   - frameworks/native (binder implementation)
#   - system/tools/aidl (AIDL compiler)
#   - external/fmtlib (formatting library)
#   - system/logging (Android logging)
#   - system/libbase (Android base library)
#   - system/core (core utilities)
#   - external/googletest (testing framework)
#   - prebuilts/build-tools (build tools with kernel headers)
#
# After cloning, applies patches from patches/ directory.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "${SCRIPT_DIR}"

# Source environment
. "${SCRIPT_DIR}/setup-env.sh"

# Android TAG
TAG="android-13.0.0_r74"

# Android AOSP binder repositories
REPOSITORIES=(
    "https://android.googlesource.com/platform/frameworks/native"
    "https://android.googlesource.com/platform/system/tools/aidl"
    "https://android.googlesource.com/platform/external/fmtlib"
    "https://android.googlesource.com/platform/system/logging"
    "https://android.googlesource.com/platform/system/libbase"
    "https://android.googlesource.com/platform/system/core"
    "https://android.googlesource.com/platform/external/googletest"
    "https://android.googlesource.com/platform/prebuilts/build-tools"
)

echo "=========================================="
echo "  Cloning Android Source Repositories"
echo "=========================================="
echo "Tag:             ${TAG}"
echo "Target dir:      ${ANDROID_DIR}"
echo "Repositories:    ${#REPOSITORIES[@]}"
echo "=========================================="

# Remove existing android directory
if [ -d "${ANDROID_DIR}" ]; then
    echo "==> Removing existing android directory..."
    rm -rf "${ANDROID_DIR}"
fi

# Create android directory
mkdir -p "${ANDROID_DIR}"
cd "${ANDROID_DIR}"

# Clone each repository
for REPO in "${REPOSITORIES[@]}"; do
    BASENAME=$(basename "${REPO}")
    echo ""
    echo "==> Cloning ${BASENAME}..."

    if ! git clone -c advice.detachedHead=false --depth 1 -b "${TAG}" "${REPO}"; then
        echo "ERROR: Failed to clone ${REPO}"
        exit 1
    fi

    # Apply patch if exists
    PATCH="${SCRIPT_DIR}/patches/${BASENAME}.patch"
    if [ -f "${PATCH}" ]; then
        echo "    Applying patch: ${BASENAME}.patch"
        pushd "${BASENAME}" > /dev/null
        if ! git apply "${PATCH}"; then
            echo "ERROR: Failed to apply patch to ${BASENAME}"
            popd > /dev/null
            exit 2
        fi
        popd > /dev/null
        echo "    ✅ Patch applied successfully"
    else
        echo "    No patch file found (${BASENAME}.patch)"
    fi

    echo "    ✅ ${BASENAME} cloned successfully"
done

cd "${SCRIPT_DIR}"

# Verify and fetch missing headers from bionic if needed
echo ""
echo "=========================================="
echo "  ✅ All Android repositories cloned"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  - Build target libraries: ./build-linux-binder-aidl.sh"
echo "  - Build AIDL tools:       ./build-aidl-generator-tool.sh"
echo "  - Build example:          ./build-binder-example.sh"
echo ""
