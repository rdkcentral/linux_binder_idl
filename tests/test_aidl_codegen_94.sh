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
# Regression test for issue #94 - defects in the aidl generator patch.
#
#   1. Constant expressions are overflow-checked at their own width: 64-bit
#      arithmetic that fits in 64 bits generates with the right value, and
#      32-bit overflow is still rejected.
#   2. Generated code compiles with -Wall -Wextra -Werror at C++17 against
#      the SDK headers on the normal include path: an interface (HASHVALUE is
#      const char*), an enum (no bare clang pragmas), a union (its unreachable
#      branches end in a [[noreturn]] call), and the SDK headers themselves
#      (no clang-only attributes). A client that takes VERSION by reference
#      links (VERSION is inline).
#
# Uses the built host generator (out/host/bin/aidl) and the target SDK
# (out/target). Skips cleanly (exit 0) when either has not been built, or when
# the target SDK is not for this host's architecture (cross builds).
set -uo pipefail

HERE="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
AIDL="${ROOT}/out/host/bin/aidl"
SDK="${ROOT}/out/target"
CXX="${CXX:-g++}"

skip() { echo "  SKIP  #94 aidl codegen test - $1"; exit 0; }
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }
FAILED=0

[ -x "${AIDL}" ] || skip "host aidl not built (run build-aidl-generator-tool.sh)"
command -v "${CXX}" >/dev/null 2>&1 || skip "${CXX} not installed"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/codegen94.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/aidl/com/x" "${WORK}/src" "${WORK}/hdr"
gen() { "${AIDL}" --lang=cpp -I "${WORK}/aidl" -o "${WORK}/src" -h "${WORK}/hdr" "$@"; }

# 1. Overflow checking at the constant's own width.
cat > "${WORK}/aidl/com/x/IWide.aidl" <<'AIDL'
package com.x;
interface IWide {
    const long BIG = 2147483647L + 1L;
    const long MUL = 65536L * 65536L;
    const long NEG = -2147483648L - 1L;
    void ping();
}
AIDL
if gen "${WORK}/aidl/com/x/IWide.aidl" > "${WORK}/wide.log" 2>&1; then
    H="${WORK}/hdr/com/x/IWide.h"
    if grep -q 'BIG = 2147483648L' "${H}" && grep -q 'MUL = 4294967296L' "${H}" \
        && grep -q 'NEG = -2147483649L' "${H}"; then
        pass "64-bit constant arithmetic generates with 64-bit values"
    else
        fail "64-bit constants generated with wrong values"
    fi
else
    fail "64-bit constant arithmetic rejected: $(tail -1 "${WORK}/wide.log")"
fi

printf 'package com.x;\ninterface INarrow { const int I = 2147483647 + 1; void ping(); }\n' \
    > "${WORK}/aidl/com/x/INarrow.aidl"
if gen "${WORK}/aidl/com/x/INarrow.aidl" > "${WORK}/narrow.log" 2>&1; then
    fail "32-bit constant overflow was not rejected"
elif grep -q 'overflows' "${WORK}/narrow.log"; then
    pass "32-bit constant overflow is still rejected"
else
    fail "32-bit overflow rejected for another reason: $(tail -1 "${WORK}/narrow.log")"
fi

# 2. Generated header: -Werror at C++17, and VERSION usable by reference.
printf 'package com.x;\n@Backing(type="int") enum Mode { A = 0, B = 1 }\n' > "${WORK}/aidl/com/x/Mode.aidl"
printf 'package com.x;\nimport com.x.Mode;\nunion Val { int a; long b; Mode m; }\n' > "${WORK}/aidl/com/x/Val.aidl"
printf 'package com.x;\nimport com.x.Val;\ninterface IIdent { Val get(); }\n' > "${WORK}/aidl/com/x/IIdent.aidl"
for f in Mode Val; do
    gen "${WORK}/aidl/com/x/${f}.aidl" > "${WORK}/${f}.log" 2>&1 || { fail "${f} does not generate"; exit 1; }
done
if ! gen --version=1 --hash=abc123 "${WORK}/aidl/com/x/IIdent.aidl" > "${WORK}/ident.log" 2>&1; then
    fail "versioned interface does not generate: $(tail -1 "${WORK}/ident.log")"
    exit 1
fi
[ -d "${SDK}/include" ] && [ -d "${SDK}/lib" ] || { [ "${FAILED}" -eq 0 ] || exit 1; skip "target SDK not built"; }

cat > "${WORK}/client.cpp" <<'CPP'
#include <com/x/IIdent.h>
#include <algorithm>
int pick(int32_t v) { return std::max(com::x::IIdent::VERSION, v); }  // ODR-uses VERSION
const char* hash() { return com::x::IIdent::HASHVALUE; }
int main(int argc, char**) { return pick(argc) == 1 && hash()[0] == 'a' ? 0 : 1; }
CPP
FLAGS=(-std=c++17 -Wall -Wextra -Werror -I "${WORK}/hdr" -I "${SDK}/include")
CC_OK=1
for src in IIdent Val Mode; do
    [ -f "${WORK}/src/com/x/${src}.cpp" ] || continue
    "${CXX}" "${FLAGS[@]}" -c "${WORK}/src/com/x/${src}.cpp" -o "${WORK}/${src}.o" >> "${WORK}/cc.log" 2>&1 || CC_OK=0
done
"${CXX}" "${FLAGS[@]}" -c "${WORK}/client.cpp" -o "${WORK}/client.o" >> "${WORK}/cc.log" 2>&1 || CC_OK=0
if [ "${CC_OK}" -eq 1 ]; then
    pass "generated interface, enum and union compile with -Wall -Wextra -Werror at C++17"
else
    fail "generated code does not compile cleanly: $(grep -m1 'error' "${WORK}/cc.log")"
fi

# Built without -Werror, so the link check stands on its own.
if "${CXX}" -std=c++17 -w -I "${WORK}/hdr" -I "${SDK}/include" -c "${WORK}/src/com/x/IIdent.cpp" \
        -o "${WORK}/IIdent_l.o" >> "${WORK}/cc.log" 2>&1 \
    && "${CXX}" -std=c++17 -w -I "${WORK}/hdr" -I "${SDK}/include" -c "${WORK}/src/com/x/Val.cpp" \
        -o "${WORK}/Val_l.o" >> "${WORK}/cc.log" 2>&1 \
    && "${CXX}" -std=c++17 -w -I "${WORK}/hdr" -I "${SDK}/include" -c "${WORK}/client.cpp" \
        -o "${WORK}/client_l.o" >> "${WORK}/cc.log" 2>&1; then
    if "${CXX}" "${WORK}/IIdent_l.o" "${WORK}/Val_l.o" "${WORK}/client_l.o" -L "${SDK}/lib" -lbinder -lutils -llog -lbase -lcutils \
        -Wl,-rpath,"${SDK}/lib" -o "${WORK}/client" > "${WORK}/ld.log" 2>&1; then
        if "${WORK}/client"; then
            pass "client taking VERSION by reference links and runs"
        else
            fail "client ran but returned the wrong VERSION or HASHVALUE"
        fi
    elif grep -qE 'file in wrong format|incompatible|skipping incompatible' "${WORK}/ld.log"; then
        echo "  SKIP  link: target SDK is not built for this host's architecture"
    else
        fail "client does not link: $(grep -m1 -E 'undefined|error' "${WORK}/ld.log")"
    fi
else
    fail "generated interface does not compile even without -Werror"
fi

[ "${FAILED}" -eq 0 ]
