#!/usr/bin/env bash

#/**
# * Copyright 2026 RDK Management
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
#
# Test-suite runner for the linux_binder_idl toolchain. Auto-discovers and runs
# every tests/test_*.sh and tests/test_*.py, aggregates results, and exits
# non-zero if any test fails.
#
# These are TESTS, run on demand — they do not gate the build (build_binder.sh
# / build-aidl-generator-tool.sh run independently). A test reports its own
# PASS/FAIL/SKIP lines; a SKIP (missing optional tooling) is not a failure.
#
# Usage:
#   ./tests/run-tests.sh              # run the whole suite
#   ./tests/run-tests.sh -k version   # only tests whose name matches 'version'
set -uo pipefail

HERE="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
FILTER="${2:-}"
[ "${1:-}" = "-k" ] || FILTER=""

mapfile -t TESTS < <(find "${HERE}" -maxdepth 1 \( -name 'test_*.sh' -o -name 'test_*.py' \) -type f | sort)
[ -n "${FILTER}" ] && mapfile -t TESTS < <(printf '%s\n' "${TESTS[@]}" | grep -- "${FILTER}" || true)

echo "========================================="
echo "  linux_binder_idl test suite"
echo "  discovered: ${#TESTS[@]} test(s)"
echo "========================================="

PASS=0; FAIL=0; FAILED_NAMES=()
for t in "${TESTS[@]}"; do
    name="$(basename "${t}")"
    echo ""
    echo "── ${name} ──"
    case "${t}" in
        *.py) runner=(python3 "${t}") ;;
        *)    runner=(bash "${t}") ;;
    esac
    if "${runner[@]}"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); FAILED_NAMES+=("${name}")
    fi
done

echo ""
echo "========================================="
echo "  suite: ${PASS} passed, ${FAIL} failed (of ${#TESTS[@]})"
[ "${FAIL}" -gt 0 ] && printf '  failed: %s\n' "${FAILED_NAMES[*]}"
echo "========================================="
[ "${FAIL}" -eq 0 ]
