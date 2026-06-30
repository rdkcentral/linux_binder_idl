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
# Regression test for issue #35 — binder must build against OLD kernel UAPI
# headers (4.9 floor), not just 5.16+.
#
# libbinder's binder_module.h carries `#ifndef BINDER_FREEZE` /
# `#ifndef BINDER_GET_FROZEN_INFO` fallback definitions so it compiles when the
# kernel's <linux/android/binder.h> predates process-freeze (added ~5.10) — as
# 4.9 does. A regression disabled those fallbacks (wrapped them in `#if 0` and
# made BINDER_GET_FROZEN_INFO unconditional) on a "require 5.16+" assumption,
# which breaks the build against 4.9 headers (undefined struct
# binder_frozen_status_info / BINDER_FREEZE).
#
# This test applies patches/native.patch to the upstream binder_module.h, then
# compiles a translation unit that exercises the freeze symbols against a
# 4.9-style UAPI header that intentionally LACKS them. With the fallbacks
# active it compiles; with them disabled it fails — catching the regression.
#
# Skips cleanly (exit 0) when the AOSP source or a compiler is unavailable.
set -uo pipefail

HERE="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
PATCH="${ROOT}/patches/native.patch"
CXX="${CXX:-g++}"

skip() { echo "  SKIP  #35 4.9-fallback test — $1"; exit 0; }
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; exit 1; }

command -v "${CXX}" >/dev/null 2>&1 || skip "${CXX} not installed"
[ -f "${PATCH}" ] || skip "patches/native.patch not found"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/binder49.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# Obtain the upstream binder_module.h (the patch target). Prefer a local AOSP
# checkout; otherwise fetch just the one file at the pinned tag.
TAG="$(grep -oE 'android-[0-9.]+_r[0-9]+' "${ROOT}/clone-android-binder-repo.sh" | head -1)"
SRC=""
for c in "${ROOT}/android/frameworks/native" /tmp/aosp-native /tmp/aosp-verify; do
    [ -f "${c}/libs/binder/binder_module.h" ] && { SRC="${c}"; break; }
done
mkdir -p "${WORK}/libs/binder"
if [ -n "${SRC}" ]; then
    cp "${SRC}/libs/binder/binder_module.h" "${WORK}/libs/binder/binder_module.h"
elif command -v curl >/dev/null 2>&1 && [ -n "${TAG}" ]; then
    url="https://android.googlesource.com/platform/frameworks/native/+/refs/tags/${TAG}/libs/binder/binder_module.h?format=TEXT"
    curl -fsSL "${url}" 2>/dev/null | base64 -d > "${WORK}/libs/binder/binder_module.h" 2>/dev/null \
        || skip "could not fetch binder_module.h@${TAG}"
else
    skip "no AOSP source and no curl to fetch binder_module.h"
fi
[ -s "${WORK}/libs/binder/binder_module.h" ] || skip "binder_module.h unavailable"

# Apply only the binder_module.h hunk(s) of native.patch.
( cd "${WORK}" && git init -q && git apply --include='libs/binder/binder_module.h' "${PATCH}" 2>/dev/null ) \
    || true   # if the patch no longer touches the file (fixed), that's fine

# A 4.9-era <linux/android/binder.h>: the base ioctl surface, but NO freeze
# support (binder_frozen_status_info / BINDER_FREEZE / BINDER_GET_FROZEN_INFO).
mkdir -p "${WORK}/uapi49/linux/android"
cat > "${WORK}/uapi49/linux/android/binder.h" <<'EOF'
#ifndef _UAPI_LINUX_BINDER_H_49
#define _UAPI_LINUX_BINDER_H_49
#include <linux/types.h>
#include <linux/ioctl.h>
/* 4.9-era subset: enough for binder_module.h's non-freeze references.
 * Deliberately omits BINDER_FREEZE / BINDER_GET_FROZEN_INFO and their structs
 * so the fallbacks in binder_module.h must supply them. */
#define BINDER_CURRENT_PROTOCOL_VERSION 8
struct binder_version { __s32 protocol_version; };
#define BINDER_VERSION _IOWR('b', 9, struct binder_version)
#endif
EOF

# TU exercising the freeze symbols the patched header is responsible for.
cat > "${WORK}/probe.c" <<'EOF'
#include <stdint.h>   /* uint32_t used by the freeze fallback structs */
#include <linux/android/binder.h>
#include "libs/binder/binder_module.h"
int probe(void) {
    struct binder_freeze_info fi = {0};
    struct binder_frozen_status_info si = {0};
    (void)fi; (void)si;
    return (int)(BINDER_FREEZE ^ BINDER_GET_FROZEN_INFO);
}
EOF

echo "  compiling against a 4.9-style UAPI header (no freeze support) ..."
if "${CXX}" -c -I"${WORK}/uapi49" -I"${WORK}" "${WORK}/probe.c" -o "${WORK}/probe.o" 2>"${WORK}/cc.err"; then
    pass "#35: binder_module.h freeze fallbacks compile against 4.9 headers"
else
    echo "    ---- compiler error (fallbacks missing → #35 regression) ----"
    grep -E 'error:|binder_freeze_info|binder_frozen_status_info|BINDER_FREEZE' "${WORK}/cc.err" | head -8 | sed 's/^/    /'
    fail "#35: build fails against 4.9 headers — pre-5.16 fallbacks are disabled in binder_module.h"
fi
