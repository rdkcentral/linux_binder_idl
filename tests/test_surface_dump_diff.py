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
# Regression test for issue #27 — `aidl_ops dump-surface` / `diff-surface`.
#
# Exercises the classification rule table: every row maps a structural AIDL
# change to breaking / major / none. Declaration order is ABI (transaction
# ids / parcel order), so removal, change and reordering are breaking while
# append-only changes are major. Doc-comment-only edits must produce
# byte-identical dumps.
#
# Run: python3 tests/test_surface_dump_diff.py   (exit 0 = pass)

import os
import subprocess
import sys
import tempfile
import unittest

HOST_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "host")
sys.path.insert(0, HOST_DIR)
import aidl_surface  # noqa: E402

BASE_IFACE = """
package com.rdk.test;
/** Doc comment. */
@VintfStability
interface IThing {
    const @utf8InCpp String serviceName = "thing";
    void alpha(in int a);
    int beta(in String b, out long[] c);
}
"""

BASE_PARCEL = """
package com.rdk.test;
@VintfStability
parcelable Config {
    int width;
    @nullable String label;
}
"""

BASE_ENUM = """
package com.rdk.test;
@Backing(type="int") @VintfStability
enum Mode {
    OFF = 0,
    ON = 1,
    AUTO,
}
"""


def dump(*sources):
    with tempfile.TemporaryDirectory() as d:
        for i, src in enumerate(sources):
            with open(os.path.join(d, "f%d.aidl" % i), "w",
                      encoding="utf-8") as f:
                f.write(src)
        return aidl_surface.dump_surface(d)


def classify(old, new):
    return aidl_surface.diff_surface(dump(*old), dump(*new))


class TestDump(unittest.TestCase):

    def test_deterministic(self):
        self.assertEqual(dump(BASE_IFACE, BASE_PARCEL, BASE_ENUM),
                         dump(BASE_IFACE, BASE_PARCEL, BASE_ENUM))

    def test_doc_comments_stripped(self):
        redocumented = BASE_IFACE.replace(
            "/** Doc comment. */", "/** A totally different doc. */")
        self.assertEqual(dump(BASE_IFACE), dump(redocumented))

    def test_implicit_enum_backing_ints(self):
        self.assertIn("AUTO = 2", dump(BASE_ENUM))

    def test_nested_type(self):
        src = """
        package com.rdk.test;
        @VintfStability
        parcelable Outer {
            parcelable Id { int value; }
            int x;
        }
        """
        text = dump(src)
        self.assertIn("parcelable com.rdk.test.Outer.Id", text)
        self.assertIn("parcelable com.rdk.test.Outer\n    int x", text)


class TestDiffRuleTable(unittest.TestCase):
    """One test per row of the #27 classification rule table."""

    def assertClass(self, expected, old, new, kind=None):
        report = classify(old, new)
        self.assertEqual(expected, report["class"], report)
        if kind:
            self.assertIn(kind, [c["kind"] for c in report["changes"]],
                          report)

    def test_no_change_is_none(self):
        self.assertClass("none", [BASE_IFACE, BASE_ENUM],
                         [BASE_IFACE, BASE_ENUM])

    def test_method_removed_breaking(self):
        new = BASE_IFACE.replace("void alpha(in int a);", "")
        self.assertClass("breaking", [BASE_IFACE], [new], "method_removed")

    def test_method_signature_changed_breaking(self):
        new = BASE_IFACE.replace("void alpha(in int a);",
                                 "void alpha(in long a);")
        self.assertClass("breaking", [BASE_IFACE], [new], "method_changed")

    def test_method_added_at_end_major(self):
        new = BASE_IFACE.replace(
            "}", "    void gamma();\n}")
        self.assertClass("major", [BASE_IFACE], [new], "method_added")

    def test_method_inserted_mid_list_breaking(self):
        new = BASE_IFACE.replace(
            "void alpha(in int a);",
            "void alpha(in int a);\n    void inserted();")
        self.assertClass("breaking", [BASE_IFACE], [new],
                         "method_reordered")

    def test_field_removed_breaking(self):
        new = BASE_PARCEL.replace("int width;", "")
        self.assertClass("breaking", [BASE_PARCEL], [new], "field_removed")

    def test_field_reordered_breaking(self):
        new = BASE_PARCEL.replace(
            "int width;\n    @nullable String label;",
            "@nullable String label;\n    int width;")
        self.assertClass("breaking", [BASE_PARCEL], [new],
                         "field_reordered")

    def test_field_type_changed_breaking(self):
        new = BASE_PARCEL.replace("int width;", "long width;")
        self.assertClass("breaking", [BASE_PARCEL], [new], "field_changed")

    def test_field_appended_major(self):
        new = BASE_PARCEL.replace("}", "    int height;\n}")
        self.assertClass("major", [BASE_PARCEL], [new], "field_added")

    def test_enum_value_removed_breaking(self):
        new = BASE_ENUM.replace("AUTO,", "")
        self.assertClass("breaking", [BASE_ENUM], [new],
                         "enum_value_removed")

    def test_enum_backing_int_changed_breaking(self):
        new = BASE_ENUM.replace("ON = 1,", "ON = 5,")
        self.assertClass("breaking", [BASE_ENUM], [new],
                         "enum_value_changed")

    def test_enum_value_added_major(self):
        new = BASE_ENUM.replace("}", "    ECO = 7,\n}")
        self.assertClass("major", [BASE_ENUM], [new], "enum_value_added")

    def test_vintf_stability_removed_breaking(self):
        new = BASE_PARCEL.replace("@VintfStability\n", "")
        self.assertClass("breaking", [BASE_PARCEL], [new],
                         "annotation_removed")

    def test_new_type_added_major(self):
        self.assertClass("major", [BASE_IFACE], [BASE_IFACE, BASE_PARCEL],
                         "type_added")

    def test_type_removed_breaking(self):
        self.assertClass("breaking", [BASE_IFACE, BASE_PARCEL],
                         [BASE_IFACE], "type_removed")

    def test_const_added_major(self):
        new = BASE_IFACE.replace(
            "const @utf8InCpp String serviceName = \"thing\";",
            "const @utf8InCpp String serviceName = \"thing\";\n"
            "    const int LIMIT = 4;")
        self.assertClass("major", [BASE_IFACE], [new], "const_added")

    def test_const_type_changed_is_single_change(self):
        new = BASE_IFACE.replace("const @utf8InCpp String serviceName",
                                 "const String serviceName")
        report = classify([BASE_IFACE], [new])
        self.assertEqual("breaking", report["class"])
        kinds = [c["kind"] for c in report["changes"]]
        self.assertEqual(["const_changed"], kinds, report)

    def test_package_string_literal_not_misparsed(self):
        src = BASE_IFACE.replace(
            'serviceName = "thing"',
            'serviceName = "package com.fake; import x.Y;"')
        text = dump(src)
        self.assertIn("com.rdk.test.IThing", text)
        # the literal survives verbatim and the statement is not split on
        # the embedded semicolon
        self.assertIn('"package com.fake; import x.Y;"', text)
        self.assertNotIn("com.fake", text.split('"')[0])

    def test_structural_chars_in_string_literal(self):
        src = BASE_IFACE.replace(
            'serviceName = "thing"',
            'serviceName = "a;b{c}d"')
        text = dump(src)
        self.assertIn('"a;b{c}d"', text)
        # all members still parsed after the tricky const
        self.assertIn("void alpha(in int a)", text)
        self.assertIn("int beta(in String b, out long[] c)", text)

    def test_whitespace_inside_string_is_a_real_change(self):
        new = BASE_IFACE.replace('= "thing"', '= "th  ing"')
        self.assertIn('"th  ing"', dump(new))   # preserved verbatim
        report = classify([BASE_IFACE], [new])
        self.assertEqual("breaking", report["class"])
        self.assertEqual(["const_changed"],
                         [c["kind"] for c in report["changes"]], report)

    def test_const_changed_breaking(self):
        new = BASE_IFACE.replace('= "thing"', '= "other"')
        self.assertClass("breaking", [BASE_IFACE], [new],
                         "const_changed")


class TestCli(unittest.TestCase):

    def test_aidl_ops_dispatch_round_trip(self):
        with tempfile.TemporaryDirectory() as d:
            src_dir = os.path.join(d, "aidl")
            os.makedirs(src_dir)
            with open(os.path.join(src_dir, "IThing.aidl"), "w",
                      encoding="utf-8") as f:
                f.write(BASE_IFACE)
            old = os.path.join(d, "old.txt")
            new = os.path.join(d, "new.txt")
            ops = os.path.join(HOST_DIR, "aidl_ops.py")
            for out in (old, new):
                rc = subprocess.call(
                    [sys.executable, ops, "dump-surface", src_dir,
                     "--out", out])
                self.assertEqual(0, rc)
            out = subprocess.run(
                [sys.executable, ops, "diff-surface", old, new, "--json"],
                capture_output=True, text=True)
            self.assertEqual(0, out.returncode, out.stderr)
            self.assertIn('"class": "none"', out.stdout)


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=1).result
    ok = result.wasSuccessful()
    print("%s: test_surface_dump_diff (%d tests)"
          % ("PASS" if ok else "FAIL", result.testsRun))
    sys.exit(0 if ok else 1)
