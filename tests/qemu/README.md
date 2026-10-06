# QEMU binder round-trip test

Optional, on-demand test that boots a target kernel under QEMU and runs a
Binder **round-trip** against that kernel's driver. It is the runtime gate for
the kernel-floor / protocol / bitness work ([#35](https://github.com/rdkcentral/linux_binder_idl/issues/35), [#36](https://github.com/rdkcentral/linux_binder_idl/pull/36) — pre-5.16 freeze fallbacks so 4.9 builds).

**Why QEMU, not Docker:** Binder is a kernel driver, and Docker containers
share the host kernel — a container matrix would only ever test one kernel.
QEMU boots a real kernel per target, so the binder driver under test is the one
that varies.

## What it checks

The guest first reports the security modules the kernel is running
(`QEMU_BINDER_LSM: …`), then starts `servicemanager`. `binder_roundtrip`:

1. Opens `/dev/binder` via `ProcessState` — libbinder's strict `BINDER_VERSION`
   check here catches a kernel/userspace **protocol mismatch** (the 7-vs-8 trap).
2. Registers a test service with `servicemanager`,
3. Fetches it back (a proxy routed through the kernel), and
4. Transacts (41 → 42), exercising Parcel marshal → kernel → `onTransact` → reply.

A single sentinel line is emitted and parsed by the host runner:
`QEMU_BINDER_RESULT: PASS …` / `FAIL …`.

## The passes each kernel gets

Each kernel is booted several times, once per userspace below. Every pass
starts `servicemanager` and goes through it, on an AppArmor-only kernel
([Security module](#security-module)).

| Pass (label suffix) | Kernels | Userspace | What it proves | Expected |
| --- | --- | --- | --- | --- |
| explicit (none) | all | built with `BINDER_PROTOCOL` and `TARGET_BITNESS` set to the kernel's | this kernel and this protocol interoperate | PASS |
| `[derived]` | all | built with neither switch, so the build picks the protocol itself | the default (protocol 8) reaches a real build and matches the kernel | PASS |
| `[derived] [expected mismatch]` | protocol 7 (`-ipc32`) | built with neither switch | the default is deliberately wrong on a legacy kernel, and the boot fails with the driver's `protocol(7) does not match user space protocol(8)` rather than shipping | PASS when that message appears |
| `[32-bit userspace]` | x86_64 | i386 build | the binder driver's compat path — 32-bit processes on a 64-bit kernel | PASS |
| `[server64-client32]`, `[server32-client64]` | x86_64 | one 64-bit and one 32-bit process | a call and its reply crossing between ELF classes, both directions | PASS |

The 32-bit and mixed passes need a 32-bit busybox, which `build-kernels.sh`
stages beside every i386 kernel; without an i386 kernel in the same run they
skip.

At the end the runner prints the matrix:

| Column | Meaning |
| --- | --- |
| `KERNEL` | the kernel's label (`<version>[-i386\|-ipc32]`) |
| `GUEST` | the QEMU guest architecture |
| `SERVES` | the binder protocol the kernel serves |
| `USERSPACE` | the userspace under test, as in the table above |
| `SWITCHES` | `explicit` or `derived` |
| `DERIVED` | the protocol a derived build chose |
| `RESULT` | `PASS`, `FAIL` with the reason, or `SKIP` with the missing tool |

A row also fails as `FAIL (wrong LSM)` when the guest does not report AppArmor
active and SELinux absent.

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
as well — every one of them AppArmor-only ([Security module](#security-module)).

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

## Security module

Every kernel runs **AppArmor as its only security module, SELinux off**
(`kconfig/lsm-apparmor.fragment`) — the configuration RDK platforms ship. The
x86 defconfig would otherwise enable SELinux, which no RDK platform runs.

The security module decides whether `servicemanager` can be reached at all. A
context manager that registers with `FLAT_BINDER_FLAG_TXN_SECURITY_CTX` asks the
kernel for every caller's security context, and the kernel refuses the
transaction when the module cannot supply one. AppArmor cannot for an
unconfined process, so on these kernels such a context manager is unreachable
and every `addService` / `getService` fails
([#90](https://github.com/rdkcentral/linux_binder_idl/issues/90)). SELinux
supplies every context, which is how the defconfig hid it. On Linux
`servicemanager` does not request contexts, and every row of the matrix runs on
AppArmor to keep it that way.

| Kernel | Security-context lookup in binder | Effect of a context manager requesting contexts |
| --- | --- | --- |
| 5.4, 5.10, 5.15, 5.16 | yes (mainline from 5.1) | every transaction to it refused |
| 4.9 (vanilla) | no — Android-common 4.9 kernels carry it as a backport | none |

Each kernel's security module is checked twice, because a kernel that quietly
kept SELinux would supply every context and pass whatever userspace asks for:

1. `build-kernels.sh` rejects the kernel if the merged `.config` is not
   AppArmor-only.
2. `run-qemu-test.sh` fails the row if the guest's `QEMU_BINDER_LSM` line does
   not show AppArmor active and SELinux absent.

The kernel's `variant` file records `lsm=apparmor` next to `arch=` and
`protocol=`.

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
| `kconfig/lsm-apparmor.fragment` | AppArmor-only security module, on every kernel |
