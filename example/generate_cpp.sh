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
# generate_cpp.sh
#
# Generates AIDL C++ stubs and proxies for FWManager example from .aidl sources.
#
# This script uses the aidl compiler to generate C++ code from .aidl files.
# Generated files are placed in stable/generated/ directory for use by the build.
#
# Usage: ./generate_cpp.sh [--clean]
#
# Options:
#   clean    Remove existing generated files before regenerating
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FWMANAGER_DIR="${SCRIPT_DIR}/FWManager"
AIDL_DIR="${FWMANAGER_DIR}/aidl"
GEN_DIR="${SCRIPT_DIR}/stable/generated/FWManager"

# Find aidl compiler
AIDL_BIN="${AIDL_BIN:-}"
if [ -z "$AIDL_BIN" ]; then
    # Try common locations
    if [ -x "../out/host/bin/aidl" ]; then
        AIDL_BIN="../out/host/bin/aidl"
    elif [ -x "../../out/host/bin/aidl" ]; then
        AIDL_BIN="../../out/host/bin/aidl"
    elif command -v aidl &> /dev/null; then
        AIDL_BIN="aidl"
    else
        echo "❌ Error: aidl compiler not found"
        echo "   Build the SDK first: cd .. && ./build-linux-binder-aidl.sh"
        echo "   Or set AIDL_BIN environment variable"
        exit 1
    fi
fi

echo "========================================"
echo "  FWManager AIDL Code Generation"
echo "========================================"
echo "AIDL Compiler: $AIDL_BIN"
echo "Source Dir:    $AIDL_DIR"
echo "Output Dir:    $GEN_DIR"
echo "========================================"
echo ""

# Handle clean flag (both --clean and clean)
if [ "${1:-}" = "--clean" ] || [ "${1:-}" = "clean" ]; then
    echo "Cleaning existing generated files..."
    rm -rf "$GEN_DIR"
    echo "✓ Cleaned"
    echo ""
fi

# Create output directories
mkdir -p "$GEN_DIR"
mkdir -p "$GEN_DIR/include"

# Generate code for each .aidl file
AIDL_FILES=(
    "com/test/FirmwareStatus.aidl"
    "com/test/IFirmwareUpdateStateListener.aidl"
    "com/test/IFWManager.aidl"
)

echo "Generating C++ stubs and proxies..."
for aidl_file in "${AIDL_FILES[@]}"; do
    echo "  Processing: $aidl_file"
    "$AIDL_BIN" --lang=cpp \
        -I"$AIDL_DIR" \
        "$AIDL_DIR/$aidl_file" \
        --header_out "$GEN_DIR/include" \
        -o "$GEN_DIR"

    if [ $? -ne 0 ]; then
        echo "❌ Error: Failed to generate code for $aidl_file"
        exit 1
    fi
done

echo ""
echo "========================================"
echo "  ✓ AIDL Code Generation Complete"
echo "========================================"
echo ""
echo "Generated files:"
find "$GEN_DIR" -type f \( -name "*.cpp" -o -name "*.h" \) | sort
echo ""
echo "Generated files are in: stable/generated/FWManager/"
echo ""
echo "Generated files committed to stable/generated/FWManager/"
echo ""
echo "You can now build the examples:"
echo "  cd .."
echo "  ./build-binder-example.sh"
echo ""
