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
# Exercise the reference recipe's protocol derivation - the real function, read
# out of example/yocto/linux-binder.bb, not a copy of it.
#
# What this covers that the recipe lint cannot: the lint matches text, so it
# proves a switch is mentioned and says nothing about what the recipe decides.
# This runs the decision. It is the cheap half of #73; the other half needs real
# BitBake, which catches parse and lifecycle errors this cannot see.
#
# The guards matter most. They are what turns a platform drifting back to
# protocol 7 into a build failure instead of a boot failure, and until this
# existed nothing had ever fired one.

import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
RECIPE = os.path.join(HERE, "..", "example", "yocto", "linux-binder.bb")

PASS, FAIL = 0, 0


def ok(msg):
    global PASS
    PASS += 1
    print("  PASS: %s" % msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print("  FAIL: %s" % msg)


class Fatal(Exception):
    """Stands in for bb.fatal, which aborts the build."""


class _Bb:
    @staticmethod
    def fatal(msg):
        raise Fatal(msg)


class Data:
    """The slice of BitBake's datastore the function touches."""

    def __init__(self, **kw):
        self._v = kw

    def getVar(self, key, expand=True):
        return self._v.get(key)


def load_functions():
    """Read the derivation out of the shipped recipe and make it callable."""
    with open(RECIPE) as fh:
        text = fh.read()
    defs = re.findall(r"^def \w+\(d\):\n(?:(?:[ \t].*)?\n)*", text, re.M)
    if not defs:
        print("  FAIL: no python functions found in %s" % RECIPE)
        sys.exit(1)
    ns = {"bb": _Bb}
    exec("".join(defs), ns)          # noqa: S102 - the recipe is the thing under test
    return ns


def kernel_config(body):
    d = tempfile.mkdtemp()
    with open(os.path.join(d, ".config"), "w") as fh:
        fh.write(body)
    return d


def main():
    ns = load_functions()
    protocol = ns.get("binder_protocol")
    if protocol is None:
        bad("binder_protocol() is not defined in the recipe")
        return 1
    ok("binder_protocol() loaded from the shipped recipe")

    # --- derivation from a resolved kernel config --------------------------
    cases = [
        ("symbol =y", "CONFIG_ANDROID=y\nCONFIG_ANDROID_BINDER_IPC_32BIT=y\n", "7"),
        ("symbol explicitly unset", "CONFIG_ANDROID=y\n# CONFIG_ANDROID_BINDER_IPC_32BIT is not set\n", "8"),
        ("symbol absent entirely", "CONFIG_ANDROID=y\nCONFIG_ANDROID_BINDER_IPC=y\n", "8"),
    ]
    for name, body, want in cases:
        d = Data(STAGING_KERNEL_BUILDDIR=kernel_config(body), BINDER_PROTOCOL="")
        try:
            got = protocol(d)
        except Fatal as e:
            bad("%s: unexpected fatal (%s)" % (name, e))
            continue
        if got == want:
            ok("%s -> protocol %s" % (name, want))
        else:
            bad("%s -> protocol %s, expected %s" % (name, got, want))

    # A commented-out line is not a setting. This is the shape a defconfig
    # leaves behind, and reading it as "=y" would pick the wrong protocol.
    d = Data(STAGING_KERNEL_BUILDDIR=kernel_config("#CONFIG_ANDROID_BINDER_IPC_32BIT=y\n"), BINDER_PROTOCOL="")
    if protocol(d) == "8":
        ok("a commented-out symbol is not read as set")
    else:
        bad("a commented-out symbol was read as set")

    # --- the guards --------------------------------------------------------
    d = Data(STAGING_KERNEL_BUILDDIR="", BINDER_PROTOCOL="")
    try:
        protocol(d)
        bad("no kernel config and no declared protocol: should have been fatal")
    except Fatal:
        ok("no kernel config and no declared protocol is fatal")

    d = Data(STAGING_KERNEL_BUILDDIR=kernel_config("CONFIG_ANDROID=y\n"), BINDER_PROTOCOL="7")
    try:
        protocol(d)
        bad("declared 7 against a protocol-8 kernel: should have been fatal")
    except Fatal as e:
        if "8" in str(e) and "7" in str(e):
            ok("declared protocol disagreeing with the kernel is fatal, and names both")
        else:
            bad("mismatch was fatal but the message names neither protocol: %s" % e)

    for bogus in ("9", "yes", "0"):
        d = Data(STAGING_KERNEL_BUILDDIR="", BINDER_PROTOCOL=bogus)
        try:
            got = protocol(d)
            bad("BINDER_PROTOCOL=%s silently became protocol %s" % (bogus, got))
        except Fatal:
            ok("BINDER_PROTOCOL=%s is rejected rather than mapped" % bogus)

    # A declared protocol is honoured where no kernel is in scope - an SDK build.
    d = Data(STAGING_KERNEL_BUILDDIR="", BINDER_PROTOCOL="7")
    try:
        if protocol(d) == "7":
            ok("a declared protocol is honoured with no kernel in scope")
        else:
            bad("a declared protocol was not honoured with no kernel in scope")
    except Fatal as e:
        bad("declared protocol with no kernel in scope was fatal: %s" % e)

    print("")
    if FAIL == 0:
        print("protocol derivation: %d checks passed" % PASS)
        return 0
    print("protocol derivation: %d passed, %d FAILED" % (PASS, FAIL))
    return 1


if __name__ == "__main__":
    sys.exit(main())
