# QEMU binder round-trip test

Optional, on-demand test that boots a target kernel under QEMU and runs a
Binder **round-trip** against that kernel's driver. It is the runtime gate for
the kernel-floor / protocol / bitness work ([#35](https://github.com/rdkcentral/linux_binder_idl/issues/35), [#36](https://github.com/rdkcentral/linux_binder_idl/pull/36) — pre-5.16 freeze fallbacks so 4.9 builds).

**Why QEMU, not Docker:** Binder is a kernel driver, and Docker containers
share the host kernel — a container matrix would only ever test one kernel.
QEMU boots a real kernel per target, so the binder driver under test is the one
that varies.

## What it checks

Inside the guest, `binder_roundtrip`:

1. Opens `/dev/binder` via `ProcessState` — libbinder's strict `BINDER_VERSION`
   check here catches a kernel/userspace **protocol mismatch** (the 7-vs-8 trap).
2. Registers a test service with `servicemanager`,
3. Fetches it back (a proxy routed through the kernel), and
4. Transacts (41 → 42), exercising Parcel marshal → kernel → `onTransact` → reply.

A single sentinel line is emitted and parsed by the host runner:
`QEMU_BINDER_RESULT: PASS …` / `FAIL …`.

## Usage

```bash
# 0. Install prerequisites (qemu, busybox, cpio, g++, + Buildroot deps).
./tests/install.sh           # --minimal to skip the Buildroot kernel-build deps

# 1. Build the kernel matrix (Buildroot; heavy, needs network + toolchain).
./tests/qemu/build-kernels.sh
#    or reuse a checkout / pick versions:
#    BUILDROOT=/path/to/buildroot VERSIONS="4.9.337 5.10.205" ./tests/qemu/build-kernels.sh

# 2. Boot each kernel and run the round-trip.
./tests/qemu/run-qemu-test.sh
#    single kernel / bring-your-own image:
#    ./tests/qemu/run-qemu-test.sh --kernel /path/to/bzImage
```

The runner builds the repo's own binder target libraries
(`build-linux-binder-aidl.sh`) for the guest userspace and assembles a small
initramfs (busybox + libbinder/libutils + servicemanager + the test). It **skips cleanly** (not a failure) when QEMU,
busybox, a compiler, or kernels are absent — so it never breaks a default run.

## Matrix

`build-kernels.sh` default versions span the supported range (4.9 floor → 5.16),
one stable point release per minor. Protocol/bitness axes:

| Variant | Kernel fragment | Userspace |
| --- | --- | --- |
| protocol 8 (default, mixed 32/64) | `kconfig/binder.fragment` | libbinder built without `BINDER_IPC_32BIT` |
| protocol 7 (legacy all-32-bit) | `+ kconfig/binder-ipc32.fragment` (append `:ipc32` to a version) | libbinder built with `-DBINDER_IPC_32BIT=1` |

## Extending to a HALIF interface

`binder_roundtrip.cpp` is a binder-runtime gate; it carries a marked hook to
add a generated-interface round-trip: link a snapshot's
`lib<module>-v<ver>-cpp.so`, register the `Bn<Iface>` implementation, fetch it
via `I<Iface>::asInterface(...)`, and assert a method result.

## Files

| File | Role |
| --- | --- |
| `build-kernels.sh` | Buildroot matrix kernel builder → `kernels/<ver>/bzImage` |
| `run-qemu-test.sh` | builds SDK + test, assembles initramfs, boots each kernel, reports |
| `binder_roundtrip.cpp` | in-guest binder round-trip (+ HALIF hook) |
| `guest-init.sh` | guest PID 1: provision binder device, run test, poweroff |
| `kconfig/binder.fragment` | kernel binder config (protocol 8) |
| `kconfig/binder-ipc32.fragment` | legacy protocol-7 (32-bit) overlay |
