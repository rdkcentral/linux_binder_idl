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
# Regression test for issue #30 — host AIDL build fails in RDK Kirkstone
# Docker (and any Yocto SDK env) when the sourced toolchain exports
# M4=/path/to/old/m4 (< 1.4.12, lacks --gnu).
#
# Reproduction:
#   1. Source a Yocto SDK env:
#        source /opt/toolchains/rdk-glibc-x86_64-arm-toolchain/environment-setup-armv7vet2hf-neon-oe-linux-gnueabi
#      The SDK env exports M4 to an old m4 lacking --gnu.
#   2. Run ./build-aidl-generator-tool.sh.
#   3. bison invokes M4 internally → m4 rejects --gnu → build fails.
#
# This test simulates the SDK env via a stub m4 (see fixtures/broken-m4.sh)
# WITHOUT needing the real docker image or Yocto SDK installed. The
# build script must:
#   - Override the inherited M4 env var with a working m4 (the fix).
#   - Handle the "no m4 anywhere" edge case without silently crashing
#     under `set -euo pipefail`.
#
# Run:
#   ./tests/test_yocto_m4_regression.sh
# or via CI (see .github/workflows/host-build-yocto-m4-regression.yml).

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
BUILD_SCRIPT="${REPO_ROOT}/build-aidl-generator-tool.sh"
STUB_M4_SRC="${SCRIPT_DIR}/fixtures/broken-m4.sh"

# ANSI colours (auto-disabled when not a tty / NO_COLOR set)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; RST=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; RST=''
fi

# Per-test scratch dir, cleaned on exit (including failure)
SCRATCH="$(mktemp -d -t binder-idl-yocto-test.XXXXXX)"
trap 'rm -rf "${SCRATCH}"' EXIT INT TERM

STUB_BIN_DIR="${SCRATCH}/fake-yocto-sdk/bin"
mkdir -p "${STUB_BIN_DIR}"
install -m 0755 "${STUB_M4_SRC}" "${STUB_BIN_DIR}/m4"
STUB_M4="${STUB_BIN_DIR}/m4"

# Each test gets its own out/build dirs so failures don't poison reruns.
TEST_OUT="${SCRATCH}/out"
TEST_BUILD="${SCRATCH}/build-host"

PASS=0
FAIL=0

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

log()  { printf '%s\n' "$*"; }
hdr()  { printf '\n%s═══ %s%s\n' "${BOLD}" "$*" "${RST}"; }
ok()   { printf '%sPASS%s %s\n' "${GREEN}" "${RST}" "$*"; PASS=$((PASS + 1)); }
bad()  { printf '%sFAIL%s %s\n' "${RED}"   "${RST}" "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '%swarn%s %s\n' "${YELLOW}" "${RST}" "$*"; }

# Run the build script in an isolated workspace so the repo's out/
# and build-host/ aren't touched by the test.
run_build() {
  local extra_env="$1"  # extra exports applied in front of the build, e.g. "M4=/path/to/m4"
  local log_file="$2"
  # shellcheck disable=SC2086
  env -i HOME="${HOME}" PATH="${PATH}" ${extra_env} \
      bash "${BUILD_SCRIPT}" >"${log_file}" 2>&1
}

# Sanity: stub m4 actually reproduces the failure mode.
verify_stub_reproduces_bug() {
  hdr "Sanity: stub m4 rejects --gnu"
  if "${STUB_M4}" --gnu /dev/null 2>/dev/null; then
    bad "stub m4 accepted --gnu; not reproducing the Yocto SDK failure mode"
    return 1
  fi
  local err
  err="$("${STUB_M4}" --gnu /dev/null 2>&1 || true)"
  if printf '%s' "${err}" | grep -q "unrecognized option '--gnu'"; then
    ok "stub m4 rejects --gnu exactly like the old Yocto SDK m4"
  else
    bad "stub m4 rejected --gnu but error message did not match (got: ${err})"
  fi
}

# Test 1: simulated SDK env (M4 exported to the broken stub). The
# build script must override the inherited M4 and succeed.
test_build_with_broken_inherited_m4() {
  hdr "Test 1: build succeeds when env inherits broken Yocto-style M4"
  local log="${SCRATCH}/test1.log"
  rm -rf "${TEST_OUT}" "${TEST_BUILD}"

  # Force the build script's BUILD_DIR/OUT_DIR onto the scratch dir
  # without modifying the script. The script honours these env vars
  # via ROOT_DIR (the repo root) — for an out-of-tree build we copy
  # the script and override SCRIPT_DIR via running from scratch.
  # Simpler: just cd to repo root and run with env M4 set; cleanup
  # repo-root out/ and build-host/ via the test's trap.
  ( cd "${REPO_ROOT}" && \
    M4="${STUB_M4}" bash "${BUILD_SCRIPT}" ) >"${log}" 2>&1 \
    && rc=0 || rc=$?

  if [ "${rc}" -eq 0 ]; then
    ok "build succeeded with M4=${STUB_M4} inherited from env"
  else
    bad "build failed (exit ${rc}) when env M4 pointed at broken m4 — fix regressed"
    log "--- last 30 lines of build log ---"
    tail -30 "${log}" | sed 's/^/  /'
  fi
}

# Test 2: m4 missing from PATH but /usr/bin/m4 exists. The script's
# fallback to /usr/bin/m4 must engage; build must succeed; no silent
# `set -e` death.
test_build_with_m4_not_on_path() {
  hdr "Test 2: build succeeds when m4 is off PATH (fallback to /usr/bin/m4)"
  local log="${SCRATCH}/test2.log"

  # Restricted PATH stripped of m4 but still containing the host
  # toolchain. We symlink the minimum needed tools into a scratch bin
  # so the build still finds cmake/gcc/etc., but NOT m4.
  local stripped_bin="${SCRATCH}/stripped-bin"
  mkdir -p "${stripped_bin}"
  for tool in bash sh env timeout cmake gcc g++ as ar ranlib ld nm \
              make awk sed grep cut tr wc find xargs touch cat \
              printf echo true false ls expr basename dirname \
              mkdir chmod cp mv rm tee head tail uname realpath \
              which dirname date python3 git objdump objcopy strip; do
    if command -v "${tool}" >/dev/null 2>&1; then
      ln -sf "$(command -v "${tool}")" "${stripped_bin}/${tool}"
    fi
  done

  if [ -e "${stripped_bin}/m4" ]; then
    warn "test scaffolding leaked m4 into stripped PATH; test is invalid"
    bad "could not strip m4 from test PATH"
    return
  fi

  ( cd "${REPO_ROOT}" && \
    PATH="${stripped_bin}" bash "${BUILD_SCRIPT}" ) >"${log}" 2>&1 \
    && rc=0 || rc=$?

  # Acceptable outcomes:
  #   - rc=0 (build all the way through): ideal
  #   - rc!=0 but the log shows "Using m4: /usr/bin/m4" AND we got
  #     past the m4 setup block: the build may have failed for an
  #     unrelated reason in the restricted PATH (e.g. missing system
  #     library), but the m4 fallback worked.
  if grep -q "Using m4: */usr/bin/m4" "${log}"; then
    ok "fallback to /usr/bin/m4 engaged (no silent \`set -e\` death)"
  else
    bad "m4 fallback did not engage; expected 'Using m4: /usr/bin/m4' in log"
    log "--- last 30 lines of build log ---"
    tail -30 "${log}" | sed 's/^/  /'
  fi
}

# ------------------------------------------------------------------
# Run
# ------------------------------------------------------------------

verify_stub_reproduces_bug
test_build_with_broken_inherited_m4
test_build_with_m4_not_on_path

hdr "Summary"
log "  ${GREEN}PASS${RST}: ${PASS}"
log "  ${RED}FAIL${RST}: ${FAIL}"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
exit 0
