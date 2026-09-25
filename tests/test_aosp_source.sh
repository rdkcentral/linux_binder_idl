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
# Test for issue #83 - the AOSP source tarball.
#
# aosp-source.sh runs against two local fixture repositories, so the test needs
# no network and takes seconds. It checks the properties a team relies on when
# it hosts the tarball itself:
#
#   1. The same manifest produces a byte-identical tarball, whatever the umask.
#   2. The tarball's name follows the manifest's content, not its comments.
#   3. A tarball whose sha256 does not match is refused.
#   4. Unpacking applies patches/ on top of unpatched upstream, once.
#   5. Changing a patch needs no new tarball: provision re-unpacks and re-applies.
#   6. The tarball is source only: a prebuilt binary is refused.
#   7. The repository's own manifest and sha256 file agree.
#
# Run: ./tests/test_aosp_source.sh

set -uo pipefail

HERE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$( cd "${HERE}/.." && pwd )"
SCRIPT="${ROOT}/aosp-source.sh"

FAILED=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED + 1)); }
skip() { echo "  SKIP: $1"; exit 0; }

command -v git >/dev/null || skip "git not available"
tar --sort=name --version >/dev/null 2>&1 || skip "GNU tar with --sort not available"
command -v patch >/dev/null || skip "patch not available"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aosp-source-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# --- fixture: two upstream repositories, one exported in part ---------------
make_repo() {
    local dir="$1"; shift
    git init -q "${dir}"
    git -C "${dir}" config user.email test@example.invalid
    git -C "${dir}" config user.name test
    "$@"
    git -C "${dir}" add -A
    # No hooks: a developer's global commit hooks have no business here.
    git -C "${dir}" -c core.hooksPath=/dev/null commit -q -m fixture
    git -C "${dir}" rev-parse HEAD
}
alpha_files() { printf 'one\n' > "${WORK}/up/alpha/greeting.txt"; }
beta_files()  { mkdir -p "${WORK}/up/beta/keep" "${WORK}/up/beta/drop"
                printf 'kept\n' > "${WORK}/up/beta/keep/a.txt"
                printf 'dropped\n' > "${WORK}/up/beta/drop/b.txt"
                printf '#!/bin/sh\n' > "${WORK}/up/beta/keep/run.sh"
                chmod 0755 "${WORK}/up/beta/keep/run.sh"; }
mkdir -p "${WORK}/up"
ALPHA="$(make_repo "${WORK}/up/alpha" alpha_files)"
BETA="$(make_repo "${WORK}/up/beta" beta_files)"

cat > "${WORK}/manifest" <<EOF
# fixture
tag fixture_r1
alpha file://${WORK}/up/alpha ${ALPHA}
beta  file://${WORK}/up/beta  ${BETA} keep
EOF
mkdir -p "${WORK}/patches"
cat > "${WORK}/patches/alpha.patch" <<'EOF'
--- a/greeting.txt
+++ b/greeting.txt
@@ -1 +1 @@
-one
+two
EOF

export AOSP_MANIFEST="${WORK}/manifest"
export AOSP_SHA_FILE="${WORK}/sha256"
export AOSP_PATCH_DIR="${WORK}/patches"
export AOSP_SOURCE_CACHE="${WORK}/cache"
export ANDROID_DIR="${WORK}/android"
unset AOSP_SOURCE_URI

run() { "${SCRIPT}" "$@" >"${WORK}/out.log" 2>&1; }

echo "Checking the AOSP source tarball..."

# 1. Reproducible.
NAME="$("${SCRIPT}" name)"
( umask 022; run generate --update ) || { cat "${WORK}/out.log"; fail "generate --update failed"; exit 1; }
FIRST="$(sha256sum "${AOSP_SOURCE_CACHE}/${NAME}" | cut -d' ' -f1)"
rm -f "${AOSP_SOURCE_CACHE}/${NAME}"
if ( umask 077; run generate ); then
    pass "a second generate, under another umask, matches the recorded sha256"
else
    fail "a second generate does not match the first: $(tail -1 "${WORK}/out.log")"
fi
[ "$(sha256sum "${AOSP_SOURCE_CACHE}/${NAME}" | cut -d' ' -f1)" = "${FIRST}" ] \
    && pass "the two tarballs are byte-identical" \
    || fail "the two tarballs differ"

LISTING="$(tar -tzvf "${AOSP_SOURCE_CACHE}/${NAME}")"
if printf '%s\n' "${LISTING}" | grep -q 'beta/drop'; then
    fail "a path outside the manifest's list is in the tarball"
else
    pass "only the listed paths of a partial repository are exported"
fi
if printf '%s\n' "${LISTING}" | grep -q -- '-rwxr-xr-x 0/0 .*2000-01-01 00:00 android/beta/keep/run.sh'; then
    pass "entries carry owner 0/0, the fixed mtime and a normalised mode (x kept)"
else
    fail "entry metadata is not normalised: $(printf '%s\n' "${LISTING}" | grep run.sh)"
fi

# 2. The name follows content, not comments.
sed -i '1a # another comment' "${WORK}/manifest"
[ "$("${SCRIPT}" name)" = "${NAME}" ] \
    && pass "a comment does not change the tarball's name" \
    || fail "a comment changed the tarball's name"
sed -i "s/^tag fixture_r1/tag fixture_r2/" "${WORK}/manifest"
[ "$("${SCRIPT}" name)" != "${NAME}" ] \
    && pass "a content change renames the tarball" \
    || fail "a content change kept the old name"
sed -i "s/^tag fixture_r2/tag fixture_r1/" "${WORK}/manifest"

# 3. A wrong sha256 is refused.
cp "${AOSP_SOURCE_CACHE}/${NAME}" "${WORK}/tampered.tar.gz"
printf 'x' >> "${WORK}/tampered.tar.gz"
if run unpack "${WORK}/tampered.tar.gz"; then
    fail "unpack accepted a tarball with the wrong sha256"
else
    pass "unpack refuses a tarball with the wrong sha256"
fi

# 4. Unpack applies the patches, once.
if run unpack && [ "$(cat "${ANDROID_DIR}/alpha/greeting.txt")" = "two" ]; then
    pass "unpack applies patches/ on top of upstream"
else
    fail "unpack did not leave the patched file: $(tail -1 "${WORK}/out.log")"
fi
if run apply-patches && grep -q 'already applied' "${WORK}/out.log"; then
    pass "applying the same patch set again is a no-op"
else
    fail "a second apply-patches did not recognise the applied set"
fi
if run provision && grep -q 'is current' "${WORK}/out.log"; then
    pass "provision leaves a current tree alone"
else
    fail "provision did not recognise a current tree"
fi

# 5. A changed patch re-provisions from the cached tarball.
sed -i 's/^+two$/+three/' "${WORK}/patches/alpha.patch"
if run provision && [ "$(cat "${ANDROID_DIR}/alpha/greeting.txt")" = "three" ]; then
    pass "provision re-unpacks and applies a changed patch, from the same tarball"
else
    fail "provision did not apply the changed patch: $(tail -1 "${WORK}/out.log")"
fi

# 6. A prebuilt binary is refused: the tarball is source only.
bin_files() { mkdir -p "${WORK}/up/gamma/bin"
              printf '\177ELF\002\001\001' > "${WORK}/up/gamma/bin/tool"; }
GAMMA="$(make_repo "${WORK}/up/gamma" bin_files)"
printf 'tag fixture_bin\ngamma file://%s %s\n' "${WORK}/up/gamma" "${GAMMA}" > "${WORK}/manifest-bin"
if AOSP_MANIFEST="${WORK}/manifest-bin" AOSP_SHA_FILE="${WORK}/sha256-bin" run generate --update; then
    fail "generate wrote a tarball containing a prebuilt binary"
elif grep -q 'gamma/bin/tool' "${WORK}/out.log"; then
    pass "generate refuses a prebuilt binary, and names it"
else
    fail "generate failed without naming the binary: $(tail -1 "${WORK}/out.log")"
fi

# 7. The repository's own pin is consistent.
unset AOSP_MANIFEST AOSP_SHA_FILE AOSP_PATCH_DIR
if "${SCRIPT}" sha256 >/dev/null 2>"${WORK}/err.log"; then
    pass "aosp/aosp-source.sha256 names the tarball aosp/manifest describes"
else
    fail "$(cat "${WORK}/err.log")"
fi

echo ""
if [ "${FAILED}" -eq 0 ]; then
    echo "aosp source tarball: all checks passed"
    exit 0
fi
echo "aosp source tarball: ${FAILED} check(s) failed"
exit 1
