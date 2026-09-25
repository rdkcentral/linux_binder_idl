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
#   1. It states its switches under the current names. Omitting the protocol is
#      the failure that took an integrator to a protocol-7 library on a
#      protocol-8 kernel.
#   2. It derives the protocol from the kernel's RESOLVED .config, not from a
#      defconfig, which can request a symbol the kernel no longer has and have
#      that request dropped in silence.
#   3. CMake's own install rules run, so the package is not empty.
#   4. It fetches the AOSP source tarball this revision describes, from a
#      location marked as a placeholder, and patches it in do_patch.
#   5. BUILD.md's recipe block has not drifted from it. The doc inlines the
#      recipe for readability, and two copies of one file is how they diverge.
#
# Run: ./tests/test_yocto_recipe_example.sh

set -uo pipefail

HERE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$( cd "${HERE}/.." && pwd )"
RECIPE="${ROOT}/example/yocto/linux-binder.bb"
DERIVE_INC="${ROOT}/example/yocto/binder-protocol-from-kernel.inc"
BUILD_MD="${ROOT}/BUILD.md"

FAILED=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED + 1)); }

echo "Checking the reference recipe..."

[ -f "${RECIPE}" ] || { fail "example/yocto/linux-binder.bb is missing"; exit 1; }
pass "example/yocto/linux-binder.bb exists"

# 1. What the recipe actually PASSES, which is the EXTRA_OECMAKE assignment and
#    nothing else. Scanning the whole file would let the explanatory comments
#    satisfy these checks - the comments name every switch, including ones the
#    recipe deliberately does not pass - and a green result would then say
#    nothing about the recipe.
SWITCHES="$(sed -n '/^EXTRA_OECMAKE/,/^"/p' "${RECIPE}")"
[ -n "${SWITCHES}" ] || { fail "no EXTRA_OECMAKE block in the reference recipe"; exit 1; }

for sw in "-DBUILD_HOST_AIDL=OFF"; do
    if printf '%s\n' "${SWITCHES}" | grep -qF -- "${sw}"; then
        pass "passes ${sw}"
    else
        fail "does not pass ${sw} - a recipe that omits a switch inherits a default"
    fi
done

# The protocol switch, under either spelling. BINDER_PROTOCOL is the one to
# write; BINDER_IPC_32BIT is the kernel's own name, still honoured, and reads
# backwards - so the reference recipe should be showing the clearer one.
if printf '%s\n' "${SWITCHES}" | grep -qF -- "-DBINDER_PROTOCOL="; then
    pass "passes -DBINDER_PROTOCOL= (the switch that does not invert)"
elif printf '%s\n' "${SWITCHES}" | grep -qF -- "-DBINDER_IPC_32BIT="; then
    fail "passes only the deprecated -DBINDER_IPC_32BIT=; the reference should show -DBINDER_PROTOCOL="
else
    fail "passes no protocol switch - a recipe that omits it inherits a default"
fi

# The ELF class is NOT a switch, and the reference recipe must not pass one.
# It comes from CC/CXX, so declaring it restates what the compiler already says
# - and a reader copying a bitness line into a multilib recipe is how a lib32-
# variant ends up asserting the base recipe's width. TARGET_BITNESS is shown in
# the comments as an optional assertion; that is where it belongs.
if printf '%s\n' "${SWITCHES}" | grep -qE -- "-D(TARGET_BITNESS|TARGET_LIB(32|64)_VERSION)="; then
    fail "passes a bitness switch - the ELF class follows CC/CXX and the reference should not declare it"
else
    pass "passes no bitness switch (the ELF class follows CC/CXX)"
fi

# No deprecated spelling in the recipe a reader copies.
if printf '%s\n' "${SWITCHES}" | grep -qE -- "-D(BINDER_IPC_32BIT|TARGET_LIB(32|64)_VERSION)="; then
    fail "passes a deprecated switch spelling; the reference recipe is what integrators copy"
else
    pass "passes no deprecated switch spelling"
fi

# 2. The reference recipe states the protocol outright, and it is pinned to 8
#    exactly rather than "7 or 8": every supported platform serves protocol 8,
#    so that is what the copied example must show. Accepting either would let
#    the reference recipe drift to the legacy value and still pass.
if printf '%s\n' "${SWITCHES}" | grep -qF -- '-DBINDER_PROTOCOL=8'; then
    pass "states protocol 8 outright"
else
    fail "reference recipe does not state -DBINDER_PROTOCOL=8 - every supported platform serves 8"
fi

# 3. The derivation is shipped separately, for a fleet that still needs it.
[ -f "${DERIVE_INC}" ] || { fail "binder-protocol-from-kernel.inc is missing"; }
if [ -f "${DERIVE_INC}" ]; then
    pass "binder-protocol-from-kernel.inc exists for fleets that still need it"
    if grep -qF 'STAGING_KERNEL_BUILDDIR' "${DERIVE_INC}" && grep -qF "'.config'" "${DERIVE_INC}"; then
        pass "it derives from the kernel's resolved .config"
    else
        fail "it does not read STAGING_KERNEL_BUILDDIR/.config - the defconfig is not a substitute"
    fi
    if grep -qF 'virtual/kernel:do_shared_workdir' "${DERIVE_INC}"; then
        pass "it depends on virtual/kernel:do_shared_workdir, so the .config is staged"
    else
        fail "no do_configure[depends] on virtual/kernel:do_shared_workdir"
    fi
    if grep -qF 'BINDER_PROTOCOL_RESOLVED' "${DERIVE_INC}"; then
        pass "it exposes BINDER_PROTOCOL_RESOLVED"
    else
        fail "it does not expose BINDER_PROTOCOL_RESOLVED"
    fi
    # The recipe must point at it, or nobody discovers the option exists.
    if grep -qF 'binder-protocol-from-kernel.inc' "${RECIPE}"; then
        pass "the reference recipe points at it"
    else
        fail "the reference recipe never mentions the derivation option"
    fi
fi

# 4. CMake's install rules always run. CMake skips them when it sees an SDK
#    environment, and the recipe would then package an empty runtime, so the
#    recipe clears those variables before configure and checks ${D} after
#    install. Only ACTIVE lines count, for the reason given in check 1.
ACTIVE="$(grep -v '^[[:space:]]*#' "${RECIPE}")"
if printf '%s\n' "${ACTIVE}" | grep -qE 'unset[[:space:]]+OECORE_NATIVE_SYSROOT[[:space:]]+OECORE_TARGET_SYSROOT'; then
    pass "clears the SDK environment before configure"
else
    fail "does not unset OECORE_NATIVE_SYSROOT OECORE_TARGET_SYSROOT - CMake would skip its install rules"
fi
if printf '%s\n' "${ACTIVE}" | grep -qF 'bbfatal' && printf '%s\n' "${ACTIVE}" | grep -qF '${libdir}/libbinder.so'; then
    pass "do_install fails when the runtime is missing from \${D}"
else
    fail "do_install does not check that libbinder.so reached \${D}"
fi

# 5. The AOSP sources come from the source tarball, fetched in do_fetch, and the
#    recipe cannot drift from the tarball this revision describes. The location
#    is a placeholder - each team hosts the tarball itself - and must stay
#    unmistakably one: a reserved .invalid host, and a comment saying so.
WANT_NAME="$("${ROOT}/aosp-source.sh" name 2>/dev/null)"
WANT_SHA="$("${ROOT}/aosp-source.sh" sha256 2>/dev/null)"
if printf '%s\n' "${ACTIVE}" | grep -qF "AOSP_SOURCE_NAME = \"${WANT_NAME}\""; then
    pass "AOSP_SOURCE_NAME is ${WANT_NAME}, the tarball aosp/manifest describes"
else
    fail "AOSP_SOURCE_NAME is not ${WANT_NAME} - run ./aosp-source.sh name"
fi
if printf '%s\n' "${ACTIVE}" | grep -qF "SRC_URI[aosp.sha256sum] = \"${WANT_SHA}\""; then
    pass "SRC_URI[aosp.sha256sum] matches aosp/aosp-source.sha256"
else
    fail "SRC_URI[aosp.sha256sum] is not ${WANT_SHA} - run ./aosp-source.sh sha256"
fi
if printf '%s\n' "${ACTIVE}" | grep -qE '^SRC_URI \+= "\$\{AOSP_SOURCE_URI\};name=aosp;'; then
    pass "SRC_URI fetches the tarball from AOSP_SOURCE_URI"
else
    fail "SRC_URI does not fetch \${AOSP_SOURCE_URI} as name=aosp"
fi
if printf '%s\n' "${ACTIVE}" | grep -qE '^AOSP_SOURCE_URI \?= "https://[^/"]+\.invalid/' \
   && grep -qF 'AOSP_SOURCE_URI IS A PLACEHOLDER' "${RECIPE}"; then
    pass "AOSP_SOURCE_URI is a marked placeholder on a reserved .invalid host"
else
    fail "AOSP_SOURCE_URI must default to a .invalid host under an 'IS A PLACEHOLDER' comment"
fi
if printf '%s\n' "${ACTIVE}" | grep -qF 'do_patch[postfuncs] += "linux_binder_aosp_patches"' \
   && printf '%s\n' "${ACTIVE}" | grep -qF 'aosp-source.sh apply-patches --android-dir ${S}/android'; then
    pass "do_patch applies patches/ with aosp-source.sh"
else
    fail "the recipe does not apply patches/ from do_patch with aosp-source.sh"
fi

# 6. BUILD.md has not drifted. Every non-blank line of the doc's bitbake block
#    must appear in the recipe; the recipe may carry more (its licence header,
#    SRC_URI, systemd) than the doc chooses to show.
#
#    Only the FIRST bitbake block, which is the reference recipe. BUILD.md has a
#    second one - the two-line `require binder-protocol-from-kernel.inc` snippet
#    - and collecting both made this check demand lines the recipe is not
#    supposed to contain. It passed anyway, because the recipe carries that
#    snippet as a COMMENT and grep -F matches inside it: a green result standing
#    on commented-out text rather than on the recipe.
BLOCK="$(awk '/^```bitbake$/{if(!seen){seen=1;f=1;next}} /^```$/{if(f)exit} f' "${BUILD_MD}")"
if [ -z "${BLOCK}" ]; then
    fail "no bitbake block found in BUILD.md"
else
    # An ACTIVE line in the doc must match an ACTIVE line in the recipe. Matching
    # the whole file would let a commented-out copy satisfy the check, so
    # commenting out EXTRA_OECMAKE while leaving the explanation above it would
    # stay green - the same false-green the extraction above already had to fix.
    # Comment lines in the doc block are matched against the whole recipe,
    # because that is what they are there.
    # Both haystacks are FILES, not pipelines. `printf ... | grep -q` looks
    # equivalent and is not: grep -q exits at the first match, printf takes
    # SIGPIPE with the rest still unwritten, and `set -o pipefail` reports the
    # pipeline as failed - so a line that matched EARLY in the recipe was
    # reported as drifted while one matching near the end passed. A false
    # failure that depended on where in the file the match happened to be.
    ACTIVE_FILE="$(mktemp "${TMPDIR:-/tmp}/binder-recipe-active.XXXXXX")"
    trap 'rm -f "${ACTIVE_FILE}"' EXIT
    grep -v '^[[:space:]]*#' "${RECIPE}" > "${ACTIVE_FILE}"
    missing=0
    while IFS= read -r line; do
        [ -z "${line//[[:space:]]/}" ] && continue
        case "${line}" in
            \#*) grep -qF -- "${line}" "${RECIPE}" \
                    || { echo "         drifted (comment): ${line}"; missing=$((missing + 1)); } ;;
            *)  grep -qF -- "${line}" "${ACTIVE_FILE}" \
                    || { echo "         drifted: ${line}"; missing=$((missing + 1)); } ;;
        esac
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
