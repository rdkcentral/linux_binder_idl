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
| `test_qemu_binder.sh` → [`qemu/`](qemu/) | binder **round-trip on a real kernel** under QEMU — the runtime gate for the kernel-floor / protocol / bitness work (#35/#36) |

## QEMU binder round-trip (`qemu/`)

`test_qemu_binder.sh` is a thin wrapper for the harness in [`qemu/`](qemu/),
which boots each target kernel under QEMU and runs a Binder round-trip against
that kernel's driver — the one thing a Docker/container matrix can't do (containers
share the host kernel). It builds the binder target libraries + `servicemanager`,
assembles a small initramfs, and boots the kernel matrix. Heavy and opt-in:

```bash
./tests/install.sh              # prerequisites (qemu, busybox, cpio, g++, Buildroot deps)
./tests/qemu/build-kernels.sh   # build the kernel matrix (4.9 floor → 5.16)
./tests/run-tests.sh -k qemu    # or ./tests/qemu/run-qemu-test.sh
```

It **skips cleanly** when QEMU/busybox/a compiler or built kernels are absent, so
it never breaks a default `run-tests.sh`. See [`qemu/README.md`](qemu/README.md).
