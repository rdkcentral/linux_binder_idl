# Test suite

On-demand regression tests for the binder/AIDL toolchain. These are **tests**,
not build gates — `build_binder.sh` / `build-aidl-generator-tool.sh` run
independently; the suite is run separately to catch regressions.

```bash
./tests/run-tests.sh            # run the whole suite
./tests/run-tests.sh -k version # only tests matching a substring
```

`run-tests.sh` auto-discovers every `test_*.sh` / `test_*.py`, so new tests join
the suite as their PRs merge. Each test prints its own `PASS` / `FAIL` / `SKIP`
(a SKIP means optional tooling — a compiler, the AOSP source — is absent, and is
not a failure). The runner exits non-zero if any test fails.

| Test | Guards |
| --- | --- |
| `test_yocto_m4_regression.sh` | host AIDL build vs an old sourced `M4` (#30) |
| `test_binder_4_9_fallbacks.sh` | binder builds against 4.9 kernel UAPI headers (#35) |
| `test_cmake_min_version_compat.sh` | no CMake sub-command newer than the declared `cmake_minimum_required` (#24) |
| `test_interface_version_ordinal.py` | module-local snapshots emit the real interface VERSION ordinal (#32) |
