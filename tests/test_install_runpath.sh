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
# Test for issue #62 — a build installed outside the loader's default search
# path must record its own prefix, so the middleware and the vendor layer can
# each install this library to a prefix of their own and have each layer's
# binaries load the copy belonging to that layer.
#
# Asserted from the generated cmake_install.cmake rather than from a built
# artifact, so the test configures but does not compile. CMake writes the
# install RPATH into that script as NEW_RPATH, one entry per installed target,
# which is the same value the linker later stamps into DT_RUNPATH. Checking it
# per target is what covers the property that matters: RUNPATH goes on every
# library, not only on the executables, because DT_RUNPATH is not inherited
# transitively.
set -uo pipefail

HERE="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; exit 1; }
skip() { echo "  SKIP  $1"; exit 0; }

command -v cmake >/dev/null 2>&1 || skip "#62: cmake not available"
[ -d "${ROOT}/android/native/libs/binder" ] || \
    skip "#62: AOSP sources not checked out (run clone-android-binder-repo.sh)"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Configure only — no compile. Errors are kept for the failure message.
configure() {
    local build_dir="$1"; shift
    cmake -S "${ROOT}" -B "${build_dir}" -DBUILD_HOST_AIDL=OFF "$@" \
        > "${build_dir}.log" 2>&1
}

# Every non-empty NEW_RPATH value the install script will stamp, deduplicated.
# CMake emits NEW_RPATH "" for each target whose build-tree RPATH is stripped at
# install time, which is the no-RUNPATH outcome rather than a recorded path — so
# the pattern requires at least one character.
install_rpaths() {
    grep -o 'NEW_RPATH "[^"]\+"' "$1/cmake_install.cmake" 2>/dev/null \
        | sed 's/NEW_RPATH "//; s/"$//' | sort -u
}

# --- a separated prefix records itself -------------------------------------
configure "${WORK}/sep" -DCMAKE_INSTALL_PREFIX=/mw/usr \
    || fail "#62: configure with a separated prefix failed — see ${WORK}/sep.log"

mapfile -t rpaths < <(install_rpaths "${WORK}/sep")
if [ "${#rpaths[@]}" -eq 0 ]; then
    fail "#62: no install RPATH recorded for prefix /mw/usr — installed artifacts would not find their own dependencies"
fi
if [ "${#rpaths[@]}" -ne 1 ] || [ "${rpaths[0]}" != "/mw/usr/lib" ]; then
    printf '    recorded: %s\n' "${rpaths[@]}"
    fail "#62: install RPATH should be exactly /mw/usr/lib — a build-tree path leaking in means CMAKE_INSTALL_RPATH_USE_LINK_PATH is not OFF"
fi
pass "#62: separated prefix records /mw/usr/lib as the install RPATH"

# Each installed target gets it, not only the executable. RUNPATH is not
# inherited transitively, so libbinder.so needs its own entry to find liblog,
# libbase, libcutils and libutils in the same prefix.
targets="$(grep -c 'NEW_RPATH "/mw/usr/lib"' "${WORK}/sep/cmake_install.cmake" 2>/dev/null || true)"
if [ "${targets}" -lt 2 ]; then
    fail "#62: only ${targets} installed target(s) carry the RPATH — every library needs its own, DT_RUNPATH is not inherited"
fi
pass "#62: ${targets} installed targets carry the install RPATH"

# --- a prefix already on the default search path does not ------------------
# Emitting a RUNPATH there is redundant and is what Yocto's `useless-rpaths`
# QA check rejects, so a stock prefix must keep the behaviour it has always had.
configure "${WORK}/std" -DCMAKE_INSTALL_PREFIX=/usr \
    || fail "#62: configure with the default prefix failed — see ${WORK}/std.log"

mapfile -t std_rpaths < <(install_rpaths "${WORK}/std")
if [ "${#std_rpaths[@]}" -ne 0 ]; then
    printf '    recorded: %s\n' "${std_rpaths[@]}"
    fail "#62: /usr/lib is on the loader's default search path and must get no RUNPATH"
fi
pass "#62: a prefix on the default search path records no install RPATH"

# --- the opt-out works -----------------------------------------------------
configure "${WORK}/off" -DCMAKE_INSTALL_PREFIX=/mw/usr -DBINDER_INSTALL_RUNPATH=OFF \
    || fail "#62: configure with BINDER_INSTALL_RUNPATH=OFF failed — see ${WORK}/off.log"

mapfile -t off_rpaths < <(install_rpaths "${WORK}/off")
if [ "${#off_rpaths[@]}" -ne 0 ]; then
    printf '    recorded: %s\n' "${off_rpaths[@]}"
    fail "#62: BINDER_INSTALL_RUNPATH=OFF must suppress the install RPATH"
fi
pass "#62: BINDER_INSTALL_RUNPATH=OFF suppresses the install RPATH"

# --- new dtags, so the prefix is not overridable by LD_LIBRARY_PATH --------
# DT_RPATH is inherited transitively but LD_LIBRARY_PATH wins over it, which
# with two copies of the library installed is worse than the problem it solves.
# The flag reaches the generated link rules rather than the cache, because the
# macro sets the linker-flag variables in directory scope.
mapfile -t link_rules < <(find "${WORK}/sep/CMakeFiles" -maxdepth 2 -name link.txt 2>/dev/null | sort)
if [ "${#link_rules[@]}" -eq 0 ]; then
    skip "#62: generator produced no link.txt (not the Makefile generator) — cannot inspect link flags"
fi

with_dtags=0
for rule in "${link_rules[@]}"; do
    grep -q 'enable-new-dtags' "${rule}" && with_dtags=$((with_dtags + 1))
done

# CMAKE_CXX_COMPILER_ID is not a cache entry; it is written to the detected
# compiler module.
compiler_id="$(sed -n 's/^set(CMAKE_CXX_COMPILER_ID "\([^"]*\)").*/\1/p' \
    "${WORK}/sep"/CMakeFiles/*/CMakeCXXCompiler.cmake 2>/dev/null | head -1)"

if [ "${compiler_id}" = "GNU" ]; then
    if [ "${with_dtags}" -ne "${#link_rules[@]}" ]; then
        fail "#62: --enable-new-dtags on ${with_dtags}/${#link_rules[@]} link rules — GNU ld may emit DT_RPATH, which LD_LIBRARY_PATH overrides"
    fi
    pass "#62: --enable-new-dtags on all ${with_dtags} link rules, so DT_RUNPATH rather than DT_RPATH"
else
    pass "#62: --enable-new-dtags not required for ${compiler_id:-an unidentified compiler} (lld emits DT_RUNPATH only)"
fi
