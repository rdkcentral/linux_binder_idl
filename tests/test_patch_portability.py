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
# Patch portability check for issue #95 - tests each hunk of the five AOSP
# patches (aidl, core, libbase, logging, native) against an AOSP tag.
#
# Every hunk is cut out into a patch of its own and checked with
# `git apply --check`, forward and in reverse, against the upstream tree at
# the tag:
#
#   forward   applies cleanly: local glue, still needed at that tag
#   reverse   already present upstream: the same fix landed in AOSP
#   neither   conflicts: upstream changed the code (superseded or moved)
#   both      the hunk's context is ambiguous; read it by hand
#
# With no --tag it checks the pinned tag from clone-android-binder-repo.sh and
# fails unless every hunk, and every whole patch, applies forward - which is
# what the clone script needs. With one or more --tag options it prints a
# per-hunk report with a column per tag and exits 0; this is how a pin move
# (issue #76) is weighed.
#
# Upstream sources, first match wins, nothing is cloned:
#   --aosp DIR / $AOSP_DIR   a repo-tool AOSP tree (projects at their paths)
#   $ANDROID_DIR or android/ the clones made by clone-android-binder-repo.sh;
#                            a tag they lack is fetched into them (--depth 1)
# Neither working tree is touched: each check runs against a temporary index
# read from the tag.
#
# Skips cleanly (exit 0) when git is missing or no upstream source is found.
#
# Run: python3 tests/test_patch_portability.py
#      python3 tests/test_patch_portability.py --tag android-13.0.0_r74 \
#          --tag android-14.0.0_r1 [--patch native] [--aosp DIR]

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PATCH_DIR = os.path.join(ROOT, "patches")

# Patch name (= clone directory name) -> project path in an AOSP tree.
PROJECTS = {
    "aidl": "system/tools/aidl",
    "core": "system/core",
    "libbase": "system/libbase",
    "logging": "system/logging",
    "native": "frameworks/native",
}

FORWARD, REVERSE, NEITHER, BOTH = "forward", "reverse", "neither", "both"


def git(repo, *args, env=None, check=True):
    r = subprocess.run(["git", "-C", repo, *args], env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       universal_newlines=True)
    if check and r.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args), r.stderr.strip()))
    return r


def pinned_tag():
    with open(os.path.join(ROOT, "clone-android-binder-repo.sh")) as f:
        m = re.search(r"android-[0-9.]+_r[0-9]+", f.read())
    return m.group(0) if m else None


def split_hunks(text):
    """Return [(file, hunk_header, single_hunk_patch)] for a patch file.

    Text before the first `diff --git` (the patch's own header block) is
    dropped, as `git apply` drops it.
    """
    out = []
    sections = re.split(r"^(?=diff --git )", text, flags=re.M)
    for sec in sections:
        if not sec.startswith("diff --git "):
            continue
        lines = sec.splitlines(keepends=True)
        first = next((i for i, l in enumerate(lines) if l.startswith("@@")), None)
        if first is None:
            continue
        header = "".join(lines[:first])
        m = re.match(r"diff --git a/(\S+) b/(\S+)", lines[0])
        path = m.group(2) if m else lines[0].strip()
        starts = [i for i in range(first, len(lines)) if lines[i].startswith("@@")]
        for n, s in enumerate(starts):
            e = starts[n + 1] if n + 1 < len(starts) else len(lines)
            hunk = "".join(lines[s:e])
            out.append((path, lines[s].split("@@")[1].strip(), header + hunk))
    return out


class Upstream:
    """One AOSP project, read at a tag through a temporary index."""

    def __init__(self, name, aosp, android, work):
        self.name = name
        self.work = work
        self.repo = None
        self.fetchable = False
        candidates = []
        if aosp:
            candidates.append((os.path.join(aosp, PROJECTS[name]), False))
        if android:
            candidates.append((os.path.join(android, name), True))
        for path, fetchable in candidates:
            if os.path.exists(os.path.join(path, ".git")):
                self.repo, self.fetchable = path, fetchable
                break

    def commit(self, tag):
        ref = "refs/tags/%s^{commit}" % tag
        r = git(self.repo, "rev-parse", "--verify", "-q", ref, check=False)
        if r.returncode != 0 and self.fetchable:
            git(self.repo, "fetch", "-q", "--depth", "1", "origin",
                "tag", tag, "--no-tags", check=False)
            r = git(self.repo, "rev-parse", "--verify", "-q", ref, check=False)
        return r.stdout.strip() if r.returncode == 0 else None

    def index_for(self, tag):
        idx = os.path.join(self.work, "%s-%s.index" % (self.name, tag))
        if not os.path.exists(idx):
            sha = self.commit(tag)
            if sha is None:
                return None
            env = dict(os.environ, GIT_INDEX_FILE=idx)
            git(self.repo, "read-tree", sha, env=env)
        return idx

    def applies(self, idx, patch_file, reverse=False):
        env = dict(os.environ, GIT_INDEX_FILE=idx)
        args = ["apply", "--cached", "--check"]
        if reverse:
            args.append("--reverse")
        return git(self.repo, *args, patch_file, env=env, check=False).returncode == 0


def classify(up, idx, patch_file):
    fwd = up.applies(idx, patch_file)
    rev = up.applies(idx, patch_file, reverse=True)
    if fwd and rev:
        return BOTH
    return FORWARD if fwd else REVERSE if rev else NEITHER


def main():
    ap = argparse.ArgumentParser(
        description="Check each hunk of patches/*.patch forward and in reverse "
                    "against an AOSP tag (issue #95).")
    ap.add_argument("--tag", action="append", default=[],
                    help="AOSP tag to check against; repeat to compare tags")
    ap.add_argument("--patch", action="append", default=[], choices=sorted(PROJECTS),
                    help="limit to this patch; repeatable")
    ap.add_argument("--aosp", default=os.environ.get("AOSP_DIR"),
                    help="repo-tool AOSP tree to read (default: $AOSP_DIR)")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="print every hunk, not only the summary")
    a = ap.parse_args()

    if shutil.which("git") is None:
        print("  SKIP  #95 patch portability - git not available")
        return 0
    pinned = pinned_tag()
    report = bool(a.tag)
    tags = a.tag or ([pinned] if pinned else [])
    if not tags:
        print("  FAIL  no AOSP tag in clone-android-binder-repo.sh")
        return 1
    android = os.environ.get("ANDROID_DIR") or os.path.join(ROOT, "android")
    names = a.patch or sorted(PROJECTS)

    work = tempfile.mkdtemp(prefix="patch-portability.")
    try:
        ups = {n: Upstream(n, a.aosp, android, work) for n in names}
        missing = [n for n, u in ups.items() if u.repo is None]
        if missing:
            print("  SKIP  #95 patch portability - no upstream source for %s "
                  "(set AOSP_DIR, or run clone-android-binder-repo.sh)" % ", ".join(missing))
            return 0

        failed = 0
        width = max(len(t) for t in tags)
        for name in names:
            up = ups[name]
            with open(os.path.join(PATCH_DIR, name + ".patch")) as f:
                text = f.read()
            hunks = split_hunks(text)
            whole = os.path.join(work, name + ".patch")
            with open(whole, "w") as f:
                f.write(text)
            print("")
            print("%s.patch: %d hunks, upstream %s" % (name, len(hunks), up.repo))

            idxs = {}
            for t in tags:
                idxs[t] = up.index_for(t)
                if idxs[t] is None:
                    print("  FAIL  %s: tag %s not found in %s" % (name, t, up.repo))
                    failed += 1
            rows = []
            for i, (path, at, body) in enumerate(hunks, 1):
                hp = os.path.join(work, "%s-%03d.patch" % (name, i))
                with open(hp, "w") as f:
                    f.write(body)
                rows.append((i, path, at,
                             [classify(up, idxs[t], hp) if idxs[t] else "-" for t in tags]))

            for col, t in enumerate(tags):
                if idxs[t] is None:
                    continue
                counts = {k: sum(1 for r in rows if r[3][col] == k)
                          for k in (FORWARD, REVERSE, NEITHER, BOTH)}
                print("  %-*s  forward %2d  reverse %2d  neither %2d  both %2d" % (
                    width, t, counts[FORWARD], counts[REVERSE], counts[NEITHER], counts[BOTH]))

            if report or a.verbose:
                print("    hunk  %s  file @@ range @@" % "  ".join("%-*s" % (width, t) for t in tags))
                for i, path, at, res in rows:
                    print("    %4d  %s  %s @@ %s @@" % (
                        i, "  ".join("%-*s" % (width, r) for r in res), path, at))

            if not report and idxs[tags[0]]:
                t = tags[0]
                bad = [r for r in rows if r[3][0] != FORWARD]
                for i, path, at, res in bad:
                    print("  FAIL  %s hunk %d (%s @@ %s @@) is %s at %s"
                          % (name, i, path, at, res[0], t))
                whole_ok = up.applies(idxs[t], whole)
                if not whole_ok:
                    print("  FAIL  %s.patch does not apply as a whole at %s" % (name, t))
                if bad or not whole_ok:
                    failed += 1
                else:
                    print("  PASS  %s.patch: all %d hunks apply at %s" % (name, len(rows), t))
        return 1 if failed else 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
