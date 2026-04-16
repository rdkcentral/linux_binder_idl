#!/usr/bin/env bash
#/**
# * Copyright 2025 Comcast Cable Communications Management, LLC
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

set -euo pipefail

###########################################################
# test_build.sh
#
# Comprehensive build test for Linux Binder AIDL toolchain.
# Tests all build scripts and CMake configurations:
#   1.    Clean Android sources
#   1.1   Clone Android sources
#   2     Scripts exist and are executable
#   2.5   Default CMake flags validation
#   3     Help flags work
#   4     Clean operations
#   5     Build host AIDL tools
#   6     Build target binder libraries
#   7     Direct CMake build (defaults + install)
#   8     Direct CMake build (per BUILD.md)
#   9     Direct CMake build (per BUILD.md + install)
#   10    Production build (minimal flags + install)
#   11    SC Docker cross-compilation (RDK Kirkstone ARM)
#   12    Incremental build
###########################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "${SCRIPT_DIR}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0

# Logging
TEST_LOG="${SCRIPT_DIR}/test_build.log"
> "${TEST_LOG}"

CMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX:-$(pwd)/out/target}"

###########################################################
# Helper functions
###########################################################

usage() {
    echo "Usage: $0 [--from ID] [--to ID] [--only ID[,ID...]] [--list] [--help]"
    echo "  --from ID    Start running at test ID (e.g., 3 or 6)"
    echo "  --to ID      Stop after test ID (inclusive)"
    echo "  --only IDs   Run only specified test IDs (comma-separated)"
    echo "  --list       List available test IDs"
    echo "  --help       Show this help"
}

print_pass() {
    echo -e "${GREEN}  PASS:${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

print_fail() {
    echo -e "${RED}  FAIL:${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

print_info() {
    echo -e "${BLUE}  INFO:${NC} $1"
}

check_file_exists() {
    local file="$1"
    local description="$2"

    if [ -f "$file" ]; then
        print_pass "$description: $file"
        return 0
    else
        print_fail "$description not found: $file"
        return 1
    fi
}

check_warnings_errors() {
    local log_file="$1"
    local description="$2"

    local warning_count
    local error_count
    warning_count=$(grep -ciE "warning:" "$log_file" 2>/dev/null || echo "0")
    error_count=$(grep -ciE "error:" "$log_file" 2>/dev/null || echo "0")

    # Remove any whitespace/newlines
    warning_count=$(echo "$warning_count" | tr -d '\n\r ')
    error_count=$(echo "$error_count" | tr -d '\n\r ')
    warning_count=${warning_count:-0}
    error_count=${error_count:-0}

    if [ "$error_count" -eq 0 ] && [ "$warning_count" -eq 0 ]; then
        print_pass "$description - No warnings or errors"
        return 0
    else
        print_fail "$description - warnings: $warning_count, errors: $error_count"
        grep -iE "warning:|error:" "$log_file" 2>/dev/null | head -10 | tee -a "${TEST_LOG}"
        return 1
    fi
}

###########################################################
# Test ID management and CLI
###########################################################

TEST_IDS=("1" "1.1" "2" "2.5" "3" "4" "5" "6" "7" "8" "9" "10" "11" "12")

list_tests() {
    echo "Available tests:"
    echo "  1     Clean Android sources"
    echo "  1.1   Clone Android sources"
    echo "  2     Scripts exist and are executable"
    echo "  2.5   Default CMake flags validation"
    echo "  3     Help flags work"
    echo "  4     Clean operations work and exit"
    echo "  5     Build host AIDL tools"
    echo "  6     Build target binder libraries"
    echo "  7     Direct CMake build (defaults + install)"
    echo "  8     Direct CMake build (per BUILD.md)"
    echo "  9     Direct CMake build (per BUILD.md + install)"
    echo "  10    Production build (minimal flags + install)"
    echo "  11    SC Docker cross-compilation (RDK Kirkstone ARM toolchain)"
    echo "  12    Incremental build"
}

index_of_test_id() {
    local id="$1"
    local i=0
    for test_id in "${TEST_IDS[@]}"; do
        if [ "$test_id" = "$id" ]; then
            echo "$i"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

parse_only_ids() {
    local ids="$1"
    IFS=',' read -r -a ONLY_IDS <<< "$ids"
}

should_run_test() {
    local id="$1"
    if [ "${#ONLY_IDS[@]}" -gt 0 ]; then
        for allowed in "${ONLY_IDS[@]}"; do
            if [ "$allowed" = "$id" ]; then
                return 0
            fi
        done
        return 1
    fi
    local idx
    idx=$(index_of_test_id "$id") || return 1
    if [ "$idx" -lt "$START_INDEX" ] || [ "$idx" -gt "$END_INDEX" ]; then
        return 1
    fi
    return 0
}

run_test() {
    local id="$1"
    local name="$2"
    if should_run_test "$id"; then
        echo ""
        echo -e "${YELLOW}[$id] ${name}${NC}"
        "$3"
    else
        echo ""
        echo "[$id] ${name} (skipped)"
    fi
}

###########################################################
# Build helper functions
###########################################################

clean_build_state() {
    rm -rf ./build-host ./build-target ./build-target-cmake ./build-production ./build-default-cmake 2>/dev/null || true
    rm -rf ./out/host ./out/target 2>/dev/null || true
    rm -rf ./CMakeFiles ./CMakeCache.txt ./cmake_install.cmake 2>/dev/null || true
}

ensure_host_aidl_tools() {
    if [ -x ./out/host/bin/aidl ] && [ -x ./out/host/bin/aidl-cpp ]; then
        return 0
    fi
    echo "==> Building host AIDL tools for CMake build..."
    if ./build-aidl-generator-tool.sh >/tmp/host_build.log 2>&1; then
        print_pass "Host AIDL tools built"
        test -x ./out/host/bin/aidl && print_pass "aidl binary created"
        test -x ./out/host/bin/aidl-cpp && print_pass "aidl-cpp binary created"
    else
        print_fail "Host AIDL tools build failed"
        tail -20 /tmp/host_build.log | tee -a "${TEST_LOG}"
        exit 1
    fi
}

run_cmake_build() {
    local build_dir="$1"
    shift
    echo "==> cmake -S . -B ${build_dir} -DCMAKE_INSTALL_PREFIX=${CMAKE_INSTALL_PREFIX} $*"
    cmake -S . -B "${build_dir}" \
        -DCMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX}" \
        "$@" \
        >/tmp/cmake_target_config.log 2>&1 && \
    echo "==> cmake --build ${build_dir} -- -j$(nproc)" && \
    cmake --build "${build_dir}" -- -j"$(nproc)" \
        >/tmp/cmake_target_build.log 2>&1
}

run_cmake_install() {
    local build_dir="$1"
    echo "==> cmake --install ${build_dir} --prefix ${CMAKE_INSTALL_PREFIX}"
    cmake --install "${build_dir}" --prefix "${CMAKE_INSTALL_PREFIX}" \
        >/tmp/cmake_target_install.log 2>&1
}

print_dest_tree() {
    local dest_root="$1"
    if [ ! -d "${dest_root}" ]; then
        print_fail "Install destination not found: ${dest_root}"
        return 1
    fi
    echo "==> Install destination tree: ${dest_root}"
    if command -v tree >/dev/null 2>&1; then
        tree -a "${dest_root}"
    else
        find "${dest_root}" -print | sort
    fi
}

check_install_layout() {
    local prefix_path="${CMAKE_INSTALL_PREFIX}"
    local ok=true
    if [ ! -d "${prefix_path}/lib" ]; then
        print_fail "Missing lib directory: ${prefix_path}/lib"
        ok=false
    fi
    if [ ! -d "${prefix_path}/include" ]; then
        print_fail "Missing include directory: ${prefix_path}/include"
        ok=false
    fi
    if [ ! -d "${prefix_path}/bin" ]; then
        print_fail "Missing bin directory: ${prefix_path}/bin"
        ok=false
    fi
    if [ "${ok}" = true ]; then
        print_pass "Install layout correct (lib/, include/, bin/)"
    else
        print_dest_tree "${prefix_path}"
        return 1
    fi
    return 0
}

###########################################################
# Parse CLI arguments
###########################################################

START_INDEX=0
END_INDEX=$((${#TEST_IDS[@]} - 1))
ONLY_IDS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --from)
            shift
            start_idx=$(index_of_test_id "${1:-}") || {
                echo "Unknown test ID for --from: ${1:-}"
                list_tests
                exit 1
            }
            START_INDEX="$start_idx"
            ;;
        --to)
            shift
            end_idx=$(index_of_test_id "${1:-}") || {
                echo "Unknown test ID for --to: ${1:-}"
                list_tests
                exit 1
            }
            END_INDEX="$end_idx"
            ;;
        --only)
            shift
            parse_only_ids "${1:-}"
            ;;
        --list)
            list_tests
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

echo "=========================================="
echo "  Linux Binder AIDL - Build Test Suite"
echo "=========================================="
echo "Log file: ${TEST_LOG}"
echo ""

###########################################################
# Test functions
###########################################################

test_1() {
    echo "Cleaning Android sources..."
    rm -rf ./android 2>/dev/null || true
    print_pass "Android sources cleaned"
}

test_1_1() {
    echo "Cloning Android sources (this may take several minutes)..."
    if ./clone-android-binder-repo.sh >/tmp/clone.log 2>&1; then
        print_pass "Clone script completed"

        if [ -d "./android" ]; then
            print_pass "android/ directory created"
        else
            print_fail "android/ directory not created"
            return 1
        fi

        # Verify key repositories were cloned
        REQUIRED_REPOS=("native" "aidl" "fmtlib" "logging" "libbase" "core" "googletest" "build-tools")
        for repo in "${REQUIRED_REPOS[@]}"; do
            if [ -d "./android/${repo}" ]; then
                print_pass "Repository cloned: ${repo}"
            else
                print_fail "Repository missing: ${repo}"
            fi
        done

        if command -v du &> /dev/null; then
            android_size=$(du -sh ./android 2>/dev/null | cut -f1)
            print_info "Android source size: ${android_size}"
        fi
    else
        print_fail "Clone script failed"
        tail -20 /tmp/clone.log | tee -a "${TEST_LOG}"
        exit 1
    fi
}

test_2() {
    echo "Checking scripts..."
    if [ -x ./clone-android-binder-repo.sh ]; then
        print_pass "clone-android-binder-repo.sh is executable"
    else
        print_fail "clone-android-binder-repo.sh not found or not executable"
    fi
    if [ -x ./build-aidl-generator-tool.sh ]; then
        print_pass "build-aidl-generator-tool.sh is executable"
    else
        print_fail "build-aidl-generator-tool.sh not found or not executable"
    fi
    if [ -x ./build-linux-binder-aidl.sh ]; then
        print_pass "build-linux-binder-aidl.sh is executable"
    else
        print_fail "build-linux-binder-aidl.sh not found or not executable"
    fi
    if [ -f ./CMakeLists.txt ]; then
        print_pass "CMakeLists.txt exists"
    else
        print_fail "CMakeLists.txt not found"
    fi
}

test_2_5() {
    echo "Validating default CMake flags..."
    rm -rf ./build-default-cmake 2>/dev/null || true
    if cmake -S . -B ./build-default-cmake > /tmp/default_config.log 2>&1; then
        print_pass "Default CMake configure completed"

        if grep -q "^CMAKE_BUILD_TYPE:STRING=Release$" ./build-default-cmake/CMakeCache.txt; then
            print_pass "Default CMAKE_BUILD_TYPE is Release"
        else
            print_fail "Default CMAKE_BUILD_TYPE is not Release"
        fi

        if grep -q "^BUILD_HOST_AIDL:BOOL=ON$" ./build-default-cmake/CMakeCache.txt; then
            print_pass "Default BUILD_HOST_AIDL is ON"
        else
            print_fail "Default BUILD_HOST_AIDL is not ON"
        fi
    else
        print_fail "Default CMake configure failed"
        tail -20 /tmp/default_config.log | tee -a "${TEST_LOG}"
    fi
    rm -rf ./build-default-cmake 2>/dev/null || true
}

test_3() {
    clean_build_state
    echo "Testing --help flags..."
    if ./build-aidl-generator-tool.sh --help >/dev/null 2>&1; then
        print_pass "Host script --help works"
    else
        print_fail "Host script --help failed"
    fi
    if ./build-linux-binder-aidl.sh --help >/dev/null 2>&1; then
        print_pass "Target script --help works"
    else
        print_fail "Target script --help failed"
    fi
}

test_4() {
    clean_build_state
    echo "Testing --clean operations..."
    if ./build-aidl-generator-tool.sh --clean >/dev/null 2>&1; then
        print_pass "Host --clean completed"
    else
        print_fail "Host --clean failed"
    fi
    if [ ! -d ./build-host ] && [ ! -d ./out/host ]; then
        print_pass "Host build directories removed"
    else
        print_fail "Host build directories still exist after clean"
    fi
    if ./build-linux-binder-aidl.sh --clean >/dev/null 2>&1; then
        print_pass "Target --clean completed"
    else
        print_fail "Target --clean failed"
    fi
    if [ ! -d ./build-target ] && [ ! -d ./out/target ]; then
        print_pass "Target build directories removed"
    else
        print_fail "Target build directories still exist after clean"
    fi
}

test_5() {
    clean_build_state
    echo "Building host AIDL tools (this may take a minute)..."
    if ./build-aidl-generator-tool.sh 2>&1 | tee /tmp/host_build.log > /dev/null; then
        print_pass "Host AIDL tools build completed"
        check_warnings_errors /tmp/host_build.log "Host build"

        check_file_exists "./out/host/bin/aidl" "aidl compiler"
        check_file_exists "./out/host/bin/aidl-cpp" "aidl-cpp compiler"

        if [ -x "./out/host/bin/aidl" ]; then
            print_pass "aidl binary is executable"
        else
            print_fail "aidl binary not executable"
        fi
        if [ -x "./out/host/bin/aidl-cpp" ]; then
            print_pass "aidl-cpp binary is executable"
        else
            print_fail "aidl-cpp binary not executable"
        fi
    else
        print_fail "Host AIDL tools build failed"
        tail -20 /tmp/host_build.log | tee -a "${TEST_LOG}"
        exit 1
    fi
}

test_6() {
    clean_build_state
    echo "Building target binder libraries (this may take a minute)..."
    if ./build-linux-binder-aidl.sh 2>&1 | tee /tmp/target_build.log > /dev/null; then
        print_pass "Target binder libraries build completed"
        check_warnings_errors /tmp/target_build.log "Target build"

        for lib in libbinder.so liblog.so libbase.so libcutils.so libutils.so; do
            if [ -f "./out/target/lib/${lib}" ]; then
                print_pass "Found ${lib}"
            else
                print_fail "Missing ${lib}"
            fi
        done

        check_file_exists "./out/target/bin/servicemanager" "servicemanager binary"

        if [ -d "./out/target/include" ] && [ -n "$(ls -A ./out/target/include 2>/dev/null)" ]; then
            print_pass "Header files installed in out/target/include/"
        else
            print_fail "No header files in out/target/include/"
        fi
    else
        print_fail "Target binder libraries build failed"
        tail -20 /tmp/target_build.log | tee -a "${TEST_LOG}"
        exit 1
    fi
}

test_7() {
    clean_build_state
    echo "Building target libraries via direct CMake (defaults)..."
    ensure_host_aidl_tools
    if run_cmake_build build-target-cmake && run_cmake_install build-target-cmake; then
        check_warnings_errors /tmp/cmake_target_build.log "Default CMake build"
        check_file_exists "./build-target-cmake/libbinder.so" "libbinder.so (default CMake build)"
        check_file_exists "${CMAKE_INSTALL_PREFIX}/lib/libbinder.so" "libbinder.so (default CMake install)"
        check_install_layout
        print_dest_tree "${CMAKE_INSTALL_PREFIX}"
    else
        print_fail "Default CMake build failed"
        tail -20 /tmp/cmake_target_build.log | tee -a "${TEST_LOG}"
        if [ -f /tmp/cmake_target_install.log ]; then
            tail -20 /tmp/cmake_target_install.log | tee -a "${TEST_LOG}"
        fi
        exit 1
    fi
}

test_8() {
    clean_build_state
    echo "Building target libraries via direct CMake (per BUILD.md)..."
    ensure_host_aidl_tools
    if run_cmake_build build-target-cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_HOST_AIDL=OFF \
        -DTARGET_LIB64_VERSION=ON; then
        check_warnings_errors /tmp/cmake_target_build.log "Direct CMake build (BUILD.md)"
        check_file_exists "./build-target-cmake/libbinder.so" "libbinder.so (CMake build)"
    else
        print_fail "Direct CMake build (BUILD.md) failed"
        tail -20 /tmp/cmake_target_build.log | tee -a "${TEST_LOG}"
        exit 1
    fi
}

test_9() {
    clean_build_state
    echo "Building target libraries via direct CMake (per BUILD.md + install)..."
    ensure_host_aidl_tools
    if run_cmake_build build-target-cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_HOST_AIDL=OFF \
        -DTARGET_LIB64_VERSION=ON && \
       run_cmake_install build-target-cmake; then
        check_warnings_errors /tmp/cmake_target_build.log "Direct CMake build + install"
        check_file_exists "./build-target-cmake/libbinder.so" "libbinder.so (CMake build)"
        check_file_exists "${CMAKE_INSTALL_PREFIX}/lib/libbinder.so" "libbinder.so (CMake install)"
        check_install_layout
        print_dest_tree "${CMAKE_INSTALL_PREFIX}"
    else
        print_fail "Direct CMake build + install failed"
        tail -20 /tmp/cmake_target_build.log | tee -a "${TEST_LOG}"
        if [ -f /tmp/cmake_target_install.log ]; then
            tail -20 /tmp/cmake_target_install.log | tee -a "${TEST_LOG}"
        fi
        exit 1
    fi
}

test_10() {
    clean_build_state
    echo "Production build (minimal required flags only)..."
    echo "This simulates Yocto/BitBake with only required production variables."
    echo "No AIDL compiler - uses pre-generated C++ from binder_aidl_gen/"
    if run_cmake_build build-production \
        -DBUILD_HOST_AIDL=OFF && \
       run_cmake_install build-production; then
        check_warnings_errors /tmp/cmake_target_build.log "Production build"
        check_file_exists "./build-production/libbinder.so" "libbinder.so (production build)"
        check_file_exists "${CMAKE_INSTALL_PREFIX}/lib/libbinder.so" "libbinder.so (production install)"
        check_file_exists "${CMAKE_INSTALL_PREFIX}/bin/servicemanager" "servicemanager (production install)"

        if [ ! -f "${CMAKE_INSTALL_PREFIX}/bin/aidl" ]; then
            print_pass "AIDL compiler correctly excluded from production"
        else
            print_fail "AIDL compiler should NOT be in production install"
        fi
        if [ ! -f "${CMAKE_INSTALL_PREFIX}/bin/aidl-cpp" ]; then
            print_pass "AIDL-CPP correctly excluded from production"
        else
            print_fail "AIDL-CPP should NOT be in production install"
        fi

        check_install_layout
        print_dest_tree "${CMAKE_INSTALL_PREFIX}"
    else
        print_fail "Production build failed"
        tail -20 /tmp/cmake_target_build.log | tee -a "${TEST_LOG}"
        if [ -f /tmp/cmake_target_install.log ]; then
            tail -20 /tmp/cmake_target_install.log | tee -a "${TEST_LOG}"
        fi
        exit 1
    fi
}

test_11() {
    echo "SC Docker cross-compilation test (RDK Kirkstone ARM toolchain)..."

    # Check if sc docker is available
    if ! command -v sc &> /dev/null; then
        print_info "sc command not installed - skipping cross-compilation test"
        return 0
    fi

    clean_build_state
    echo "Building with RDK Kirkstone ARM toolchain via sc docker..."
    echo "This tests cross-compilation with sysroot and ARM target flags."

    # Build in SC Docker with ARM toolchain environment.
    # Skip host AIDL tool build (no-host-aidl) — host tools must be built
    # natively outside Docker, not inside the cross-compilation environment.
    if sc docker run rdk-kirkstone \
        ". /opt/toolchains/rdk-glibc-x86_64-arm-toolchain/environment-setup-armv7vet2hf-neon-oe-linux-gnueabi && \
        export TARGET_LIB32_VERSION=ON && \
        ./build-linux-binder-aidl.sh no-host-aidl" \
        >/tmp/docker_cross_build.log 2>&1; then
        print_pass "SC Docker cross-compilation completed"
        check_warnings_errors /tmp/docker_cross_build.log "SC Docker cross-compilation"
        check_file_exists "./out/target/lib/libbinder.so" "libbinder.so (ARM cross-compile)"
        check_file_exists "./out/target/bin/servicemanager" "servicemanager (ARM cross-compile)"

        # Verify ARM architecture
        if command -v file &> /dev/null; then
            file_output=$(file ./out/target/lib/libbinder.so)
            if echo "$file_output" | grep -q "ARM"; then
                print_pass "Verified ARM architecture: $file_output"
            else
                print_fail "Expected ARM binary, got: $file_output"
            fi
        fi

        # TODO: Remove this cleanup once out/ and build/ are arch-tagged
        # (e.g. out/<arch>/, build/<arch>/). Currently ./build-target and
        # ./out/target are shared across host and cross builds — the ARM
        # CMakeCache written inside the rdk-kirkstone container references
        # an OE toolchain path that does not exist on the native host,
        # which breaks the next native build (see test_12).
        clean_build_state
    else
        print_fail "SC Docker cross-compilation failed"
        tail -30 /tmp/docker_cross_build.log | tee -a "${TEST_LOG}"
        return 1
    fi
}

test_12() {
    echo "Testing incremental builds (no clean between builds)..."

    # Ensure we have a baseline build from previous tests
    if [ ! -x ./out/host/bin/aidl ]; then
        echo "==> No baseline build found, building first..."
        if ! ./build-aidl-generator-tool.sh >/tmp/host_build.log 2>&1; then
            print_fail "Baseline host build failed"
            tail -20 /tmp/host_build.log | tee -a "${TEST_LOG}"
            return 1
        fi
    fi

    echo "Testing incremental host build..."
    if ./build-aidl-generator-tool.sh >/tmp/host_rebuild.log 2>&1; then
        print_pass "Host incremental build succeeded"
    else
        print_fail "Host incremental build failed"
        tail -20 /tmp/host_rebuild.log | tee -a "${TEST_LOG}"
    fi

    if [ ! -x ./out/target/bin/servicemanager ]; then
        echo "==> No baseline target build found, building first..."
        if ! ./build-linux-binder-aidl.sh >/tmp/target_build.log 2>&1; then
            print_fail "Baseline target build failed"
            tail -20 /tmp/target_build.log | tee -a "${TEST_LOG}"
            return 1
        fi
    fi

    echo "Testing incremental target build..."
    if ./build-linux-binder-aidl.sh >/tmp/target_rebuild.log 2>&1; then
        print_pass "Target incremental build succeeded"
    else
        print_fail "Target incremental build failed"
        tail -20 /tmp/target_rebuild.log | tee -a "${TEST_LOG}"
    fi
}

###########################################################
# Run tests
###########################################################

run_test "1" "Clean Android sources" test_1
run_test "1.1" "Clone Android sources" test_1_1
run_test "2" "Scripts exist and are executable" test_2
run_test "2.5" "Default CMake flags validation" test_2_5
run_test "3" "Help flags work" test_3
run_test "4" "Clean operations work and exit" test_4
run_test "5" "Build host AIDL tools" test_5
run_test "6" "Build target binder libraries" test_6
run_test "7" "Direct CMake build (defaults + install)" test_7
run_test "8" "Direct CMake build (per BUILD.md)" test_8
run_test "9" "Direct CMake build (per BUILD.md + install)" test_9
run_test "10" "Production build (minimal flags + install)" test_10
run_test "11" "SC Docker cross-compilation (RDK Kirkstone ARM)" test_11
run_test "12" "Incremental build" test_12

###########################################################
# Summary
###########################################################

echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="

TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))
echo -e "${GREEN}Passed: ${TESTS_PASSED}/${TOTAL_TESTS}${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Failed: ${TESTS_FAILED}/${TOTAL_TESTS}${NC}"
    echo ""
    echo -e "${RED}BUILD TEST FAILED${NC}"
    echo "Check ${TEST_LOG} for details"
    exit 1
else
    echo -e "${GREEN}Failed: 0/${TOTAL_TESTS}${NC}"
    echo ""
    echo -e "${GREEN}ALL BUILD TESTS PASSED${NC}"
    echo ""
    echo "Build outputs:"
    [ -d ./out/host/bin ] && echo "  Host:   $(realpath ./out/host/bin/)"
    [ -d ./out/target/lib ] && echo "  Target: $(realpath ./out/target/lib/)"
    [ -d ./out/target/include ] && echo "  Headers: $(realpath ./out/target/include/)"
    exit 0
fi
