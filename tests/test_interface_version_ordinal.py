#!/usr/bin/env python3
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
# Regression test for issue #32 — module-local snapshots must emit a real
# interface VERSION ordinal (getInterfaceVersion()), not always 1.
#
# Exercises aidl_gen_rule.resolve_emit_version directly, asserting:
#   - a frozen module-local snapshot with `version: N` emits N (not gen_version),
#   - an unset version, or a non-module-local layout, falls back to gen_version
#     (preserving current/ behaviour),
#   - a pinned version on a 'notfrozen' contract is rejected,
#   - a non-positive / non-integer version is rejected.
#
# Run: python3 tests/test_interface_version_ordinal.py   (exit 0 = pass)

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host"))
import aidl_gen_rule  # noqa: E402

R = aidl_gen_rule.resolve_emit_version
FROZEN = "ab12cd34"          # a real contract hash
GEN = "1"                    # resolution version (the historical emit value)


class ResolveEmitVersion(unittest.TestCase):
    def test_frozen_snapshot_emits_ordinal(self):
        self.assertEqual(R("module-local", "2", GEN, FROZEN, "IFoo"), "2")
        self.assertEqual(R("module-local", 20000, GEN, FROZEN, "IFoo"), "20000")

    def test_unset_version_falls_back_to_gen_version(self):
        self.assertEqual(R("module-local", None, GEN, FROZEN, "IFoo"), GEN)

    def test_non_module_local_ignores_version(self):
        # Even with a version set, a non-module-local layout keeps gen_version.
        self.assertEqual(R("global", "2", GEN, FROZEN, "IFoo"), GEN)

    def test_pinned_version_requires_frozen_hash(self):
        with self.assertRaises(RuntimeError):
            R("module-local", "2", GEN, "notfrozen", "IFoo")

    def test_rejects_non_positive_or_non_integer(self):
        for bad in ("0", "-1", "x", "1.0", ""):
            with self.assertRaises(RuntimeError):
                R("module-local", bad, GEN, FROZEN, "IFoo")


if __name__ == "__main__":
    unittest.main(verbosity=2)
