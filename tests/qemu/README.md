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

For each kernel the runner builds the repo's own binder target libraries
(`build-linux-binder-aidl.sh`) **at that kernel's protocol**, into the run's own
work dir, and assembles a matching initramfs (busybox + libbinder/libutils +
servicemanager + the test). Variants are cached across the kernels that share
them. It **skips cleanly** (not a failure) when QEMU, busybox, a compiler, a
32-bit toolchain, or kernels are absent — so it never breaks a default run.

## Matrix

`build-kernels.sh` default versions span the supported range (4.9 floor → 5.16),
one stable point release per minor, plus both 32-bit kernels at the 4.9 floor.

There are three kinds of kernel, and the default `VERSIONS` list builds eight
images across them:

| Variant | Guest | Kernel fragment | Userspace |
| --- | --- | --- | --- |
| protocol 8, 64-bit (default) | x86_64 | `kconfig/binder.fragment` | `-DBINDER_PROTOCOL=8` |
| protocol 8, 32-bit kernel | i386 (append `:i386`) | `kconfig/binder.fragment`, plus `binder-ipc32-off.fragment` and the prompt patch at 4.17 or older | `-DBINDER_PROTOCOL=8`, compiled `-m32` |
| protocol 7 (legacy all-32-bit) | i386, kernel ≤ 4.17 (append `:ipc32`) | `+ kconfig/binder-ipc32.fragment` | `-DBINDER_PROTOCOL=7`, compiled `-m32` |

The default list is `4.9.337 4.9.337:i386 4.9.337:ipc32 5.4.290 5.4.290:i386
5.10.205 5.15.148 5.16.20` — the supported range at one stable point release per
minor, with 4.9 carried at **both** protocols and 5.4 carried as a 32-bit kernel
as well.

The middle row is the one most platforms run: a 32-bit userspace on a modern
binder driver. At 4.18 and newer the symbol is gone and the plain fragment is
enough. At 4.17 or older it takes a **kernel patch**, because 4.9 declares
`CONFIG_ANDROID_BINDER_IPC_32BIT` as a bare `bool` with no prompt string, so
kconfig discards a `# ... is not set` line from a fragment and recomputes
`default y`. `patches/linux-4.9-binder-ipc32-prompt.patch` adds the prompt that
makes clearing it possible, and `build-kernels.sh` applies it automatically for
`:i386` on those versions — which is why `4.9.337:i386` is in the default list.
That pairing is what makes the same kernel version appear at both protocols,
which is exactly what is seen in production on identical silicon.

Protocol 7 is only reachable on a **32-bit kernel at 4.17 or older**: upstream
declares `CONFIG_ANDROID_BINDER_IPC_32BIT` as `depends on !64BIT` and removed it
in 4.18. `build-kernels.sh` therefore builds `:ipc32` variants as an i386 guest,
rejects `:ipc32` on 4.18+, and verifies the option survived the config merge
before accepting the kernel — and equally refuses a protocol-8 variant whose
config came out with the option set. Each kernel directory carries a `variant` file
(`arch=`, `protocol=`) that the runner uses to pick the QEMU binary and the
matching userspace.

## Extending to a HALIF interface

`binder_roundtrip.cpp` is a binder-runtime gate; it carries a marked hook to
add a generated-interface round-trip: link a snapshot's
`lib<module>-v<ver>-cpp.so`, register the `Bn<Iface>` implementation, fetch it
via `I<Iface>::asInterface(...)`, and assert a method result.

## Files

| File | Role |
| --- | --- |
| `build-kernels.sh` | Buildroot matrix kernel builder → `kernels/<label>/{bzImage,variant}` |
| `run-qemu-test.sh` | builds a per-protocol SDK + test, assembles initramfs, boots each kernel, reports |
| `binder_roundtrip.cpp` | in-guest binder round-trip (+ HALIF hook) |
| `guest-init.sh` | guest PID 1: provision binder device, run test, poweroff |
| `kconfig/binder.fragment` | kernel binder config (protocol 8) |
| `kconfig/binder-ipc32.fragment` | legacy protocol-7 (32-bit) overlay |
