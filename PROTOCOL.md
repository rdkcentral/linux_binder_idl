# Binder Protocol Switch Matrix

Which switches to build the binder library with, for which target kernel.

## The failure this prevents

The binder wire protocol is fixed at compile time on **both** sides. The kernel's is set by
`CONFIG_ANDROID_BINDER_IPC_32BIT`; the library's by `BINDER_IPC_32BIT`. libbinder compares them
for exact equality when it opens the driver, and there is no fallback — the process terminates:

```text
Binder driver '/dev/binder' could not be opened.
Terminating: Binder driver protocol(7) does not match user space protocol(8)!
```

A mismatched build compiles and links cleanly. The failure appears on the device at boot.

## Three inputs must agree

They are independent axes, and each fails at a different time.

| # | Input | Set by | Fails at |
| --- | --- | --- | --- |
| 1 | Toolchain bitness | `CC` / `CXX` | configure time, or the library will not run on the target |
| 2 | Kernel header series | the sysroot's UAPI headers | build time, loudly |
| 3 | Protocol define | `BINDER_IPC_32BIT` | **runtime, on the device** |

### The header is not the variable — the define is

It is one header describing two different ABIs, and the define selects which one you compile
against. From `linux/android/binder.h`:

```c
#ifdef BINDER_IPC_32BIT
typedef __u32 binder_size_t;
typedef __u32 binder_uintptr_t;
#else
typedef __u64 binder_size_t;
typedef __u64 binder_uintptr_t;
#endif
...
#ifdef BINDER_IPC_32BIT
#define BINDER_CURRENT_PROTOCOL_VERSION 7
#else
#define BINDER_CURRENT_PROTOCOL_VERSION 8
#endif
```

Correct headers are necessary but not sufficient: the right headers with the wrong define still
produce a library that cannot talk to the driver.

The same define also selects the `binder_size_t` typedef in the installed `binder/Parcel.h`, so a
consumer that calls the low-level API taking that type has to agree with libbinder about it.
Targets linking the `binder` CMake target inherit the define; anything built outside this
project's CMake and using that API must set it itself.

## Which kernel serves which protocol

Upstream `drivers/android/Kconfig` declares the option `depends on !64BIT` and removes it in the
4.18/4.19 window. Protocol 7 therefore exists on exactly one kind of target.

| Target kernel | `CONFIG_ANDROID_BINDER_IPC_32BIT` | Protocol served |
| --- | --- | --- |
| 32-bit, ≤ 4.17 | `=y` | **7** |
| 32-bit, ≤ 4.17 | unset | **8** |
| Any kernel ≥ 4.18 | option removed | **8** |
| Any 64-bit kernel | cannot be set | **8** |

Read the kernel's resolved `.config`, not its `defconfig`. The defconfig is an input: config
fragments and Kconfig defaults can set or clear the symbol without it appearing there. In a Yocto
build the resolved config is reachable at `${STAGING_KERNEL_BUILDDIR}/.config` via
`do_configure[depends] += "virtual/kernel:do_shared_workdir"`. On a running device,
`zcat /proc/config.gz | grep BINDER` answers it. Where no kernel config is in scope, state the
switches explicitly rather than letting the build guess.

## Two builds per platform

The binder library is built once per role, and the two roles differ only in bitness:

- **Middleware** — 32-bit, at whatever protocol the kernel serves.
- **Vendor** — 64-bit at protocol 8 where the platform supports 64-bit; 32-bit at the kernel's
  protocol where it does not.

**The protocol is a property of the platform; the bitness is a property of the role.** There is one
kernel, so it serves one protocol, and both builds must speak it. The two roles never disagree
about the protocol — only about the ELF class.

Two facts make the combinations closed rather than a matrix to be memorised. A 64-bit kernel
cannot serve protocol 7, so a 64-bit vendor build is always protocol 8. And a 32-bit kernel cannot
run 64-bit userspace, so a platform without 64-bit support has both roles at 32-bit and identical
switches — on those platforms the two builds are the same build.

## Platform combinations

Middleware is 32-bit. The kernel is 32-bit on some platforms and 64-bit on others, so the
protocol is decided per platform while the middleware's bitness stays fixed.

| Platform | Kernel | MW | Vendor | Protocol | MW build | Vendor build |
| --- | --- | --- | --- | --- | --- | --- |
| Legacy all-32-bit | 32-bit, ≤ 4.17, option `=y` | 32-bit | 32-bit | **7** | `LIB32=ON` `IPC32=ON` | same as MW |
| 32-bit kernel, option absent | 32-bit, ≥ 4.18 | 32-bit | 32-bit | **8** | `LIB32=ON` `IPC32=OFF` | same as MW |
| 64-bit kernel, 32-bit MW | 64-bit | 32-bit | 64-bit | **8** | `LIB32=ON` `IPC32=OFF` | `LIB64=ON` `IPC32=OFF` |
| All-64-bit | 64-bit | 64-bit | 64-bit | **8** | `LIB64=ON` `IPC32=OFF` | same as MW |

Three consequences worth stating plainly:

**A 32-bit middleware does not imply protocol 7.** Protocol 7 exists only on a 32-bit kernel at
4.17 or older with the option set. On every other platform — including every 64-bit kernel — a
32-bit middleware runs **protocol 8** over the kernel's compat path. Since a 32-bit toolchain
defaults to protocol 7, `-DBINDER_IPC_32BIT=OFF` is the switch the middleware needs on most
platforms, and it is never a default.

**A protocol-7 platform is all-32-bit by necessity.** A 32-bit kernel cannot run 64-bit userspace,
so the legacy row has no mixed variant.

**On a 64-bit kernel two binder libraries ship.** A 32-bit one for the middleware and a 64-bit one
for the vendor, different ELF classes, **both protocol 8**, because both talk to the same kernel.

This is why the derivation needs no per-role override. `binder_ipc32()` reads the one kernel and
returns the same answer for both builds; `SITEINFO_BITS` differs between them and selects the ELF
class. In OE the two roles are the base recipe and its `lib32-` multilib variant, so one expression
covers both.

The define reaches further than libbinder, but not as far as it first appears. `binder/Parcel.h`
switches the `binder_size_t` typedef on it, so any code calling the low-level API that takes or
returns that type — `ipcSetDataReference`, `ipcObjects` — must be built with the same value as
libbinder. Because the type is part of those signatures, a mismatch changes the mangled name and
shows up as an unresolved symbol at link time rather than as corruption at runtime.

Code that only uses the ordinary `Parcel` surface is unaffected. `Parcel`'s member layout does not
change with the define — `mObjects` is a pointer, so its size is fixed by the ABI, not by what it
points at — and the read/write methods that generated AIDL bindings call take no `binder_size_t`.
A HAL interface library therefore does not need the define; libbinder does, because it is what
speaks to the driver.

## The switches to build with

| Configuration | Target | Toolchain | Protocol | Switches |
| --- | --- | --- | --- | --- |
| **A** — Legacy all-32-bit | 32-bit kernel ≤ 4.17 with the option set | 32-bit | 7 | `-DTARGET_LIB32_VERSION=ON -DBINDER_IPC_32BIT=ON` |
| **B** — Mixed, 32-bit MW | 32-bit userspace on a protocol-8 kernel | 32-bit | 8 | `-DTARGET_LIB32_VERSION=ON -DBINDER_IPC_32BIT=OFF` |
| **C** — All-64-bit | any protocol-8 kernel | 64-bit | 8 | `-DTARGET_LIB64_VERSION=ON -DBINDER_IPC_32BIT=OFF` |

Row **B** is the one to watch: a 32-bit toolchain resolves to protocol 7 on its own, so
`-DBINDER_IPC_32BIT=OFF` is mandatory there and is never a default. Bitness follows userspace;
the protocol follows the kernel.

State all three switches explicitly in a build spec rather than relying on defaults. The defaults
follow the toolchain, so a spec that omits `BINDER_IPC_32BIT` means one thing for a 32-bit
middleware build and another for a 64-bit vendor build.

`build-linux-binder-aidl.sh` takes the same names as environment variables:

```sh
TARGET_LIB32_VERSION=ON BINDER_IPC_32BIT=OFF ./build-linux-binder-aidl.sh
```

## Deriving the switches in a Yocto build

Both switches are derivable, from different sources: the protocol from the kernel's resolved
config, the bitness from the target ABI the recipe is being built for. Nothing needs to be
hand-maintained per platform.

```bitbake
inherit cmake siteinfo

# The protocol comes from the kernel, so the recipe needs the configured kernel
# in scope. Without this the .config below is not staged yet.
do_configure[depends] += "virtual/kernel:do_shared_workdir"

def binder_ipc32(d):
    import os
    cfg = os.path.join(d.getVar('STAGING_KERNEL_BUILDDIR') or '', '.config')
    if not os.path.exists(cfg):
        bb.fatal("linux-binder: no kernel .config at %s, so the binder wire "
                 "protocol cannot be determined. Set BINDER_IPC_32BIT explicitly "
                 "for this build." % cfg)
    with open(cfg) as f:
        for line in f:
            if line.strip() == 'CONFIG_ANDROID_BINDER_IPC_32BIT=y':
                return 'ON'          # protocol 7
    # Both "# CONFIG_... is not set" and outright absence mean protocol 8.
    return 'OFF'

# SITEINFO_BITS is the word size of the target this recipe is being built for,
# which is what decides the ELF class. In a multilib build the lib32- variant
# reports 32 and the base recipe reports 64, so each gets the right answer from
# the same expression.
EXTRA_OECMAKE += "\
    -DBINDER_IPC_32BIT=${@binder_ipc32(d)} \
    ${@bb.utils.contains('SITEINFO_BITS', '32', '-DTARGET_LIB32_VERSION=ON', '-DTARGET_LIB64_VERSION=ON', d)} \
"
```

Read the resolved `.config`, never the `defconfig` — see above for why. Fail the build when no
kernel is in scope rather than defaulting: a guessed protocol builds and links, then terminates
the process on the device.

### What that resolves to for your layer

One expression, but it produces a different answer per role. Find the row you are building:

| Your layer | `SITEINFO_BITS` | Bitness switch | Protocol switch |
| --- | --- | --- | --- |
| 32-bit userspace — middleware, or vendor on a 32-bit platform | `32` | `-DTARGET_LIB32_VERSION=ON` | from the kernel: `ON` only for a 32-bit kernel ≤ 4.17 with the option set, `OFF` otherwise |
| 64-bit userspace — vendor on a 64-bit platform | `64` | `-DTARGET_LIB64_VERSION=ON` | always `OFF` |

**If you are a 32-bit layer, this is the row to get right.** A 32-bit toolchain defaults to
protocol 7, so on a protocol-8 kernel — which is every 64-bit kernel and every kernel from 4.18 —
the build must end up at `BINDER_IPC_32BIT=OFF`. Deriving from the kernel gives you that; hardcoding
`ON` because the layer is 32-bit is the mistake that produces the boot failure. In OE this layer is
usually the `lib32-` multilib variant, and it is the one that has a genuine choice to get wrong.

**If you are a 64-bit layer, the protocol is not a decision.** A 64-bit kernel cannot serve
protocol 7 — the Kconfig option is `depends on !64BIT` — so the answer is always `OFF`, and the
build refuses `-DBINDER_IPC_32BIT=ON` against a 64-bit toolchain rather than letting it through.
The derivation cannot produce a wrong answer here.

On a 64-bit platform carrying 32-bit middleware, both rows apply: the recipe is built twice, as
`linux-binder` and as `lib32-linux-binder`. `binder_ipc32()` returns `OFF` for both, because there
is one kernel serving one protocol, while `SITEINFO_BITS` differs and selects each one's ELF class.
That is the mixed configuration, expressed without a per-platform override.

The library's own guards catch a contradiction that slips through: a declared bitness that
disagrees with the compiler, or protocol 7 against a 64-bit toolchain, is refused at configure
time rather than becoming a runtime failure.

## Combinations refused at configure time

| Flags | Toolchain | Reason |
| --- | --- | --- |
| `-DBINDER_IPC_32BIT=ON` | 64-bit | protocol 7 carries 32-bit binder handles and cannot represent 64-bit pointers, and no 64-bit kernel serves it |
| `-DTARGET_LIB32_VERSION=OFF` | 32-bit | the declared bitness contradicts the compiler |
| `-DTARGET_LIB64_VERSION=ON` | 32-bit | the declared bitness contradicts the compiler |

`TARGET_LIB32_VERSION` and `TARGET_LIB64_VERSION` add no `-m32` / `-m64`: the ELF class comes from
`CC`/`CXX` alone, so the declaration has to agree with the toolchain it is given.

## Verification

`tests/qemu/run-qemu-test.sh` boots each kernel twice — once with both switches pinned, proving
the protocols interoperate, and once with neither set, proving the build derives the right
protocol from the toolchain on its own.

| Kernel | Arch | Protocol | Switches | Result |
| --- | --- | --- | --- | --- |
| 4.9.337-ipc32 | i386 | 7 | explicit | PASS — `servicemanager round-trip 41->42` |
| 4.9.337-ipc32 | i386 | 7 | derived | PASS — `servicemanager round-trip 41->42` |
| 5.4.290 | x86_64 | 8 | explicit | PASS — `servicemanager round-trip 41->42` |
| 5.4.290 | x86_64 | 8 | derived | PASS — `servicemanager round-trip 41->42` |
| 5.15.148 | x86_64 | 8 | explicit | PASS — `servicemanager round-trip 41->42` |
| 5.15.148 | x86_64 | 8 | derived | PASS — `servicemanager round-trip 41->42` |

4.9 and 5.4 sit on opposite sides of the 4.18 boundary where the kernel option ceases to exist, so
the pair establishes that protocol selection holds across it.

The negative cases are the point of the harness. A protocol-8 userspace against the protocol-7
kernel fails, reproducing the field error verbatim in the guest console. And a protocol-7 variant
of a kernel that cannot serve it is refused before anything is built:

```text
FAIL  5.4.290-ipc32: :ipc32 needs a 4.9-4.17 kernel — CONFIG_ANDROID_BINDER_IPC_32BIT was removed in 4.18
```

That refusal matters because kconfig drops an unsatisfiable symbol silently: asking for the option
on a kernel that no longer has it once produced a protocol-8 kernel labelled `-ipc32` and reported
success.

Run it with:

```sh
./tests/qemu/build-kernels.sh          # builds the kernel matrix
./tests/qemu/run-qemu-test.sh
```

Protocol 7 needs a 32-bit toolchain; install it with `./tests/install.sh --with-32bit`. Without
it the runner tests protocol 8 and skips the protocol-7 rows cleanly.

## See also

- [BUILD.md](BUILD.md) — full build documentation, cross-compilation and Yocto integration
- [tests/qemu/README.md](tests/qemu/README.md) — the kernel matrix and how variants are built
