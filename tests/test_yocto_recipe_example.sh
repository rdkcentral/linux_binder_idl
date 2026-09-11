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
# Keep example/yocto/linux-binder.bb honest.
#
# The reference recipe is the thing an integrator copies, and it is the one
# artefact here that no build consumes - nothing in this repo runs bitbake, so
# a mistake in it is invisible until it reaches someone else's image. These
# checks are what we can assert without a layer and a poky checkout:
#
#   1. It states all three switches. Omitting BINDER_IPC_32BIT is the failure
#      that took an integrator to a protocol-7 library on a protocol-8 kernel.
#   2. It derives the protocol from the kernel's RESOLVED .config, not from a
#      defconfig, which can request a symbol the kernel no longer has and have
#      that request dropped in silence.
#   3. BUILD.md's recipe block has not drifted from it. The doc inlines the
#      recipe for readability, and two copies of one file is how they diverge.
#
# Run: ./tests/test_yocto_recipe_example.sh

set -uo pipefail

HERE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$( cd "${HERE}/.." && pwd )"
RECIPE="${ROOT}/example/yocto/linux-binder.bb"
BUILD_MD="${ROOT}/BUILD.md"

FAILED=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED + 1)); }

echo "Checking the reference recipe..."

[ -f "${RECIPE}" ] || { fail "example/yocto/linux-binder.bb is missing"; exit 1; }
pass "example/yocto/linux-binder.bb exists"

# 1. All three switches stated.
for sw in "-DBUILD_HOST_AIDL=OFF" "-DBINDER_IPC_32BIT=" "TARGET_LIB32_VERSION=ON"; do
    if grep -qF -- "${sw}" "${RECIPE}"; then
        pass "states ${sw}"
    else
        fail "does not state ${sw} - a recipe that omits a switch inherits a default"
    fi
done

# 2. The decision is reportable: a variable bitbake -e can read without running
#    a task, and a line in the task log a matrix run can grep.
for v in "BINDER_PROTOCOL_RESOLVED" "BINDER_PROTOCOL_SOURCE"; do
    if grep -qF -- "${v}" "${RECIPE}"; then
        pass "exposes ${v}"
    else
        fail "does not expose ${v} - the chosen protocol must be readable without a build"
    fi
done
if grep -qF 'bbplain "binder: protocol=' "${RECIPE}"; then
    pass "states the decision in the task log"
else
    fail "does not log the resolved protocol - a matrix run has nothing to grep"
fi

# 3. Derived from the resolved .config, and from the right variable.
if grep -qF 'STAGING_KERNEL_BUILDDIR' "${RECIPE}" && grep -qF "'.config'" "${RECIPE}"; then
    pass "derives the protocol from the kernel's resolved .config"
else
    fail "does not read STAGING_KERNEL_BUILDDIR/.config - the defconfig is not a substitute"
fi
if grep -qF 'virtual/kernel:do_shared_workdir' "${RECIPE}"; then
    pass "depends on virtual/kernel:do_shared_workdir, so the .config is staged"
else
    fail "no do_configure[depends] on virtual/kernel:do_shared_workdir - the .config would not be there to read"
fi

# 4. BUILD.md has not drifted. Every non-blank line of the doc's bitbake block
#    must appear in the recipe; the recipe may carry more (its licence header,
#    SRC_URI, systemd) than the doc chooses to show.
BLOCK="$(awk '/^```bitbake$/{f=1;next} /^```$/{f=0} f' "${BUILD_MD}")"
if [ -z "${BLOCK}" ]; then
    fail "no bitbake block found in BUILD.md"
else
    missing=0
    while IFS= read -r line; do
        [ -z "${line//[[:space:]]/}" ] && continue
        grep -qF -- "${line}" "${RECIPE}" || { echo "         drifted: ${line}"; missing=$((missing + 1)); }
    done <<< "${BLOCK}"
    if [ "${missing}" -eq 0 ]; then
        pass "BUILD.md's recipe block matches example/yocto/linux-binder.bb"
    else
        fail "${missing} line(s) in BUILD.md's recipe block are not in the reference recipe"
    fi
fi

echo ""
if [ "${FAILED}" -eq 0 ]; then
    echo "reference recipe: all checks passed"
    exit 0
fi
echo "reference recipe: ${FAILED} check(s) failed"
exit 1
