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
# Regression test for issue #90 - on Linux, servicemanager must not register as
# the context manager with FLAT_BINDER_FLAG_TXN_SECURITY_CTX.
#
# With that flag the kernel looks up every caller's security context and fails
# the transaction when no LSM can supply one (AppArmor for unconfined
# processes, or no LSM at all), so nothing can reach servicemanager - which on
# Linux never reads the context anyway.
#
# The test applies patches/native.patch to the upstream ProcessState.cpp at the
# pinned tag, then preprocesses the context-manager registration twice: as the
# Linux build sees it (the flag must be absent) and as Android sees it (the
# flag must still be there).
#
# Skips cleanly (exit 0) when git or a compiler is unavailable, or when there is
# neither a local binder source clone nor curl/base64 to fetch the file.
set -uo pipefail

HERE="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
PATCH="${ROOT}/patches/native.patch"
CXX="${CXX:-g++}"

skip() { echo "  SKIP  #90 servicemanager security-context test - $1"; exit 0; }
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }
FAILED=0

command -v "${CXX}" >/dev/null 2>&1 || skip "${CXX} not installed"
command -v git >/dev/null 2>&1 || skip "git not available"

TAG="$(grep -oE 'android-[0-9.]+_r[0-9]+' "${ROOT}/clone-android-binder-repo.sh" | head -1)"
[ -n "${TAG}" ] || skip "no AOSP tag in clone-android-binder-repo.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/secctx.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/libs/binder"

# The unpatched upstream file: from the local binder source clone when there is
# one (patches/ is applied to its working tree, so HEAD is still upstream), and
# from googlesource otherwise, so an ordinary post-build run needs no network.
NATIVE="${ROOT}/android/native"
if git -C "${NATIVE}" show "HEAD:libs/binder/ProcessState.cpp" > "${WORK}/libs/binder/ProcessState.cpp" 2>/dev/null \
   && [ -s "${WORK}/libs/binder/ProcessState.cpp" ]; then
    SRC="the local clone (${NATIVE})"
else
    command -v curl >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1 \
        || skip "no local binder source clone, and no curl/base64 to fetch ProcessState.cpp@${TAG}"
    # googlesource ?format=TEXT returns the file base64-encoded.
    url="https://android.googlesource.com/platform/frameworks/native/+/refs/tags/${TAG}/libs/binder/ProcessState.cpp?format=TEXT"
    curl -fsSL "${url}" 2>/dev/null | base64 -d > "${WORK}/libs/binder/ProcessState.cpp" 2>/dev/null \
        || skip "could not fetch ProcessState.cpp@${TAG}"
    [ -s "${WORK}/libs/binder/ProcessState.cpp" ] || skip "ProcessState.cpp@${TAG} is empty"
    SRC="googlesource@${TAG}"
fi
echo "  upstream ProcessState.cpp from ${SRC}"

( cd "${WORK}" && git init -q && git apply --include='libs/binder/ProcessState.cpp' "${PATCH}" ) \
    || { echo "  FAIL  native.patch does not apply to ProcessState.cpp@${TAG}"; exit 1; }

# The initializer of the flat_binder_object becomeContextManager() registers.
awk '/^bool ProcessState::becomeContextManager\(\)/ {f=1}
     f && /flat_binder_object obj \{/ {g=1}
     g {print}
     g && /^[[:space:]]*\};/ {exit}' "${WORK}/libs/binder/ProcessState.cpp" > "${WORK}/obj.cpp"
grep -q 'flat_binder_object obj' "${WORK}/obj.cpp" \
    || { echo "  FAIL  becomeContextManager()'s flat_binder_object not found - upstream layout changed"; exit 1; }

linux="$("${CXX}" -x c++ -E -P "${WORK}/obj.cpp" 2>/dev/null)"
android="$("${CXX}" -x c++ -E -P -D__ANDROID__ "${WORK}/obj.cpp" 2>/dev/null)"

if printf '%s\n' "${linux}" | grep -q 'FLAT_BINDER_FLAG_TXN_SECURITY_CTX'; then
    fail "#90: the Linux build registers servicemanager with FLAT_BINDER_FLAG_TXN_SECURITY_CTX"
else
    pass "#90: the Linux build registers servicemanager without FLAT_BINDER_FLAG_TXN_SECURITY_CTX"
fi
if printf '%s\n' "${android}" | grep -q 'FLAT_BINDER_FLAG_TXN_SECURITY_CTX'; then
    pass "#90: an Android build still requests security contexts"
else
    fail "#90: the Android branch no longer requests FLAT_BINDER_FLAG_TXN_SECURITY_CTX"
fi

exit "${FAILED}"
