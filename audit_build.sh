#!/usr/bin/env bash

#/**
# * Copyright 2025 RDK Management
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
# @brief   Binder Toolchain Audit Script
#
# @details
# This script verifies the integrity and hermeticity of the locally built
# Android Binder toolchain. It performs three specific checks:
#
# 1. DEPENDENCY RESOLUTION (Hermetic Check):
#    Ensures that the built libraries (libbinder, libutils, etc.) link against
#    each other within the local toolchain directory, and DO NOT link against
#    system libraries in /usr/lib.
#
# 2. BLOAT ANALYSIS (Orphan Check):
#    Scans the 'lib/' directory for .so files that are not in the strict
#    allow-list and checks if any other binary actually uses them. If not,
#    they are flagged as orphans to be removed.
#
# 3. DEPLOYMENT FOOTPRINT (Size):
#    Calculates the total size of the core requirements (stripped of debug symbols)
#    to estimate the impact on the target embedded filesystem.
#
# @usage   ./audit_build.sh
#          BINDER_SDK_DIR=/custom/path ./audit_build.sh
#
# @env     BINDER_SDK_DIR - Override SDK location (default: ../../out/target)
#
# @output  Logs PASS/FAIL for dependencies and detailed size metrics.
# ==============================================================================

# Calculate paths relative to WHERE THIS SCRIPT IS, not where you run it from.
SCRIPT_DIR=$(dirname "$(realpath "$0")")

# Assuming the script sits in 'build-tools/linux_binder_idl/'
# Navigate to repository root, then to SDK output directory
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SDK_DIR="${BINDER_SDK_DIR:-$REPO_ROOT/out/target}"
LIB_DIR="$SDK_DIR/lib/binder"
BIN_DIR="$SDK_DIR/bin"
INC_DIR="$SDK_DIR/include/binder_sdk"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  BINDER TOOLCHAIN AUDIT${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e "  SDK Dir: $SDK_DIR"
echo -e "  Lib Dir: $LIB_DIR"
echo -e "  Bin Dir: $BIN_DIR"
echo -e "  Inc Dir: $INC_DIR"

if [ ! -d "$SDK_DIR" ]; then
    echo -e "${RED}❌ Error: SDK not found at $SDK_DIR${NC}"
    echo -e "   Run ./install_binder.sh first to build the SDK"
    exit 1
fi

if [ ! -d "$LIB_DIR" ]; then
    echo -e "${RED}❌ Error: Binder libraries not found at $LIB_DIR${NC}"
    exit 1
fi

export LD_LIBRARY_PATH="$LIB_DIR:$LD_LIBRARY_PATH"

# ==============================================================================
# CHECK 1: INTEGRITY CHECK (Hermeticity)
# ==============================================================================
echo ""
echo -e "${YELLOW}>>> [1] INTEGRITY CHECK (ldd)${NC}"
echo "    Verifying libraries link against local toolchain, not /usr/lib..."

verify_binary() {
    local bin="$1"
    local name=$(basename "$bin")
    
    if [ ! -f "$bin" ]; then return; fi

    deps=$(ldd "$bin" 2>&1)
    if echo "$deps" | grep -q "not found"; then
        echo -e "${RED}  ❌ $name: Missing dependencies!${NC}"
        echo "$deps" | grep "not found"
    else
        leaks=0
        for target in libbinder.so libutils.so libcutils.so liblog.so libbase.so; do
            if echo "$deps" | grep -q "$target"; then
                resolved_path=$(echo "$deps" | grep "$target" | awk '{print $3}')
                if [[ "$resolved_path" != "$LIB_DIR"* ]]; then
                    echo -e "${RED}  ❌ $name: Links to SYSTEM $target ($resolved_path)${NC}"
                    leaks=1
                fi
            fi
        done
        if [ $leaks -eq 0 ]; then
            echo -e "${GREEN}  ✅ $name: OK (Hermetic)${NC}"
        fi
    fi
}

verify_binary "$BIN_DIR/servicemanager"
for lib in "$LIB_DIR"/*.so; do
    if [ ! -L "$lib" ]; then verify_binary "$lib"; fi
done

# ==============================================================================
# CHECK 2: LIBRARY BLOAT ANALYSIS
# ==============================================================================
echo ""
echo -e "${YELLOW}>>> [2] LIBRARY BLOAT CHECK${NC}"

# The Strict Golden List of libraries
ALLOWED_LIBS="libbinder.so|libutils.so|libcutils.so|liblog.so|libbase.so|libcutils_sockets.so"

FOUND_LIB_BLOAT=0
for file in "$LIB_DIR"/*; do
    filename=$(basename "$file")
    if [[ -f "$file" && ! -L "$file" ]]; then
        if [[ ! "$filename" =~ ^($ALLOWED_LIBS)$ ]]; then
            # Filter versioned files (libbinder.so.1)
            base_name=$(echo "$filename" | sed 's/\.so.*/.so/')
            if [[ ! "$base_name" =~ ^($ALLOWED_LIBS)$ ]]; then
                echo -e "${RED}  ⚠️  BLOAT: Unneeded library found: $filename${NC}"
                FOUND_LIB_BLOAT=1
            fi
        fi
    fi
done

if [ $FOUND_LIB_BLOAT -eq 0 ]; then
    echo -e "${GREEN}  ✅ Libraries are clean (No extra .so files).${NC}"
fi

# ==============================================================================
# CHECK 3: HEADER BLOAT ANALYSIS
# ==============================================================================
echo ""
echo -e "${YELLOW}>>> [3] HEADER BLOAT CHECK${NC}"
echo "    Verifying include/ contains only required folders..."

# The Strict Golden List of Top-Level Directories
# 1. android      -> Core definitions
# 2. android-base -> libbase headers
# 3. binder       -> libbinder headers
# 4. cutils       -> libcutils headers
# 5. log          -> liblog headers
# 6. utils        -> libutils headers
ALLOWED_DIRS="android|android-base|binder|cutils|log|utils"

FOUND_HEADER_BLOAT=0

if [ -d "$INC_DIR" ]; then
    for dir in "$INC_DIR"/*; do
        if [ -d "$dir" ]; then
            dirname=$(basename "$dir")
            if [[ ! "$dirname" =~ ^($ALLOWED_DIRS)$ ]]; then
                echo -e "${RED}  ⚠️  BLOAT: Extra include directory: include/$dirname${NC}"
                echo "      (This suggests you are installing headers for internal tools like gtest or fmt)"
                FOUND_HEADER_BLOAT=1
            fi
        fi
    done
else
     echo -e "${RED}❌ Error: Include directory missing!${NC}"
fi

# Deep check for 'android/' folder (Common place for dumping junk)
# We only want binder-specific headers here.
if [ -d "$INC_DIR/android" ]; then
    for header in "$INC_DIR/android"/*; do
        hname=$(basename "$header")
        # We allow log.h and binder_*.h
        if [[ ! "$hname" == "log.h" && ! "$hname" == binder_* ]]; then
             echo -e "${RED}  ⚠️  BLOAT: Unexpected header in android/: $hname${NC}"
             FOUND_HEADER_BLOAT=1
        fi
    done
fi

if [ $FOUND_HEADER_BLOAT -eq 0 ]; then
    echo -e "${GREEN}  ✅ Headers are clean (Only required directories present).${NC}"
fi

# ==============================================================================
# CHECK 4: DEPLOYMENT FOOTPRINT
# ==============================================================================
echo ""
echo -e "${YELLOW}>>> [4] DEPLOYMENT FOOTPRINT${NC}"

FILES_TO_MEASURE="$BIN_DIR/servicemanager"
for lib in ${ALLOWED_LIBS//|/ }; do
    if [ -f "$LIB_DIR/$lib" ]; then
        FILES_TO_MEASURE="$FILES_TO_MEASURE $LIB_DIR/$lib"
    fi
done

mkdir -p /tmp/binder_audit
cp $FILES_TO_MEASURE /tmp/binder_audit/ 2>/dev/null
strip --strip-all /tmp/binder_audit/* 2>/dev/null
size_bytes=$(du -bc /tmp/binder_audit/* | grep total | awk '{print $1}')
size_kb=$((size_bytes / 1024))

echo "  Total Footprint (Stripped): ${size_kb} KB"
rm -rf /tmp/binder_audit

echo -e "${CYAN}============================================================${NC}"