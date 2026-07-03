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
# Regression test for issue #24 — the build declares
# `cmake_minimum_required(VERSION 3.8)` but used `file(REAL_PATH ...)`, a
# sub-command added in CMake 3.19. On a 3.8–3.18 CMake the configure dies with
# "file does not recognize sub-command REAL_PATH". The fix uses
# `get_filename_component(... REALPATH ...)` (available since 2.x).
#
# This guard scans every CMake file for sub-commands newer than the declared
# `cmake_minimum_required`, so a regression that reintroduces a too-new command
# is caught without needing an old CMake to hand. Currently checks `file()`
# sub-commands introduced after 3.8 (REAL_PATH @3.19, others as listed).
set -uo pipefail

HERE="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; exit 1; }

# file() sub-commands that require CMake newer than the declared 3.8 floor.
# (extend as needed)
#   REAL_PATH      3.19
#   ARCHIVE_*      3.18
#   CONFIGURE      3.18
PATTERN='file *\( *(REAL_PATH|ARCHIVE_CREATE|ARCHIVE_EXTRACT|CONFIGURE)\b'

mapfile -t CMAKE_FILES < <(find "${ROOT}" \
    \( -name 'CMakeLists.txt' -o -name '*.cmake' -o -name '*.inc' \) \
    -not -path '*/.git/*' -not -path '*/output*/*' -not -path '*/.buildroot/*' 2>/dev/null | sort)

[ "${#CMAKE_FILES[@]}" -gt 0 ] || fail "no CMake files found (unexpected)"

hits="$(grep -EnH "${PATTERN}" "${CMAKE_FILES[@]}" 2>/dev/null || true)"
if [ -n "${hits}" ]; then
    echo "    too-new file() sub-command(s) vs declared cmake_minimum_required(3.8):"
    echo "${hits}" | sed 's/^/    /'
    fail "#24: CMake sub-command newer than the 3.8 floor — breaks configure on CMake 3.8–3.18"
fi
pass "#24: no file() sub-command newer than the declared cmake_minimum_required(3.8)"
