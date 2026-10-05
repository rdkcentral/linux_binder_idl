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
# Regression test for issue #81 - host/logger.py needs nothing but the
# standard library, logs to stderr, colours only a terminal, and fatal() exits.
#
# The logger cases run in a fresh interpreter started with -S, so no
# site-packages are visible. The host scripts need PyYAML, so for them colorama
# alone is made unimportable - the state of a build host without it.
#
# Run: python3 tests/test_logger.py   (exit 0 = pass)

import os
import subprocess
import sys
import unittest

HOST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host")

SCRIPT = """
import sys
sys.path.insert(0, %r)
from logger import Logger
log = Logger("tag", Logger.DEBUG)
def worker():
    log.info("info line")
    log.verbose("verbose line")
    log.error("error line")
    log.fatal("fatal line")
    print("after fatal")
worker()
""" % HOST


def run(*flags):
    return subprocess.run([sys.executable, "-S", *flags, "-c", SCRIPT],
                          capture_output=True, text=True)


class LoggerTest(unittest.TestCase):
    def test_logger_imports_without_site_packages(self):
        r = subprocess.run(
            [sys.executable, "-S", "-c", "import sys; sys.path.insert(0, %r); import logger" % HOST],
            capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_host_scripts_import_without_colorama(self):
        try:
            import yaml  # noqa: F401  (a declared prerequisite of AIDL generation)
        except ImportError:
            self.skipTest("PyYAML not installed")
        for module in ("aidl_ops", "aidl_gen_rule", "aidl_api", "aidl_interface"):
            r = subprocess.run(
                [sys.executable, "-c",
                 "import sys; sys.modules['colorama'] = None; "
                 "sys.path.insert(0, %r); import %s" % (HOST, module)],
                capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, "%s: %s" % (module, r.stderr))

    def test_records_go_to_stderr_only(self):
        r = run()
        self.assertEqual(r.stdout, "")
        self.assertIn("info line", r.stderr)

    def test_line_names_the_caller(self):
        line = next(l for l in run().stderr.splitlines() if "info line" in l)
        self.assertIn("[INFO    ] tag  worker():", line)

    def test_level_filters(self):
        self.assertNotIn("verbose line", run().stderr)

    def test_no_escape_codes_when_not_a_terminal(self):
        self.assertNotIn("\033", run().stderr)

    def test_fatal_exits_non_zero(self):
        r = run()
        self.assertEqual(r.returncode, 1)
        self.assertIn("fatal line", r.stderr)
        self.assertNotIn("after fatal", r.stdout)

    def test_fatal_exits_non_zero_under_optimisation(self):
        r = run("-O")
        self.assertEqual(r.returncode, 1)
        self.assertNotIn("after fatal", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
