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

## What the two protocols are

The protocol number selects the width of the pointer and size fields on the wire, and nothing
else. From `linux/android/binder.h`:

```c
#ifdef BINDER_IPC_32BIT
typedef __u32 binder_size_t;      /* protocol 7 */
typedef __u32 binder_uintptr_t;
#else
typedef __u64 binder_size_t;      /* protocol 8 */
typedef __u64 binder_uintptr_t;
#endif
```

| Protocol | Wire fields | Who can participate |
| --- | --- | --- |
| **7** | 32-bit | a 32-bit kernel with 32-bit userspace, exclusively |
| **8** | 64-bit | any 32-bit or 64-bit process, in any combination |

**Protocol 8 does not mean 64-bit.** It means 64-bit-wide *fields*, which a 32-bit process uses
perfectly well — it stores its 32-bit pointers in them. A wholly 32-bit platform, 32-bit kernel and
32-bit userspace throughout, runs protocol 8 normally, and on any kernel from 4.18 that is the only
option there is. Protocol 8 permits mixing; it does not require it.

Protocol 7 is not the 32-bit option, it is the **legacy-compat** option. Its 32-bit fields cannot
hold a 64-bit pointer, which is why the kernel side is `depends on !64BIT` and why nothing 64-bit
can be present anywhere on such a platform. Taking it costs the ability to mix, and upstream is
explicit about what it is for:

```text
Enable this to support an old 32-bit Android user-space (v4.4 and earlier).

Note that enabling this will break newer Android user-space.
```

8 is the current protocol; there is no 9. Note that the *userspace* header still carries the
`#ifdef` at 5.15, so a protocol-7 library can still be compiled, while the kernel-side option is
gone — a combination that guarantees a mismatch, because no modern kernel can answer it.

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

Upstream `drivers/android/Kconfig` declares the option `depends on !64BIT && ANDROID_BINDER_IPC`
with `default y`, and removes it before 5.4. Protocol 7 therefore exists on exactly one kind of
target.

| Target kernel | `CONFIG_ANDROID_BINDER_IPC_32BIT` | Protocol served |
| --- | --- | --- |
| 32-bit, ≤ 4.17, stock Kconfig | `=y` (**the default**, and not settable) | **7** |
| 32-bit, ≤ 4.17, Kconfig patched | symbol cleared or removed by a kernel change | **8** |
| Any kernel ≥ 4.18 | option removed | **8** |
| Any 64-bit kernel | cannot be set | **8** |

**`default y` matters, and the option is not user-configurable.** Upstream 4.9 declares it as a
bare `bool` with **no prompt string**:

```text
config ANDROID_BINDER_IPC_32BIT
	bool
	depends on !64BIT && ANDROID_BINDER_IPC
	default y
```

A symbol with no prompt cannot be set from a config. kconfig discards whatever a defconfig or
fragment says about it and recomputes the value from `default y`, silently. So on a stock 32-bit
kernel at 4.17 or older, protocol 7 is not a choice anyone made and not one a config can undo —
adding `# CONFIG_ANDROID_BINDER_IPC_32BIT is not set` changes nothing, and the resolved `.config`
still reads `=y`.

Moving such a platform to protocol 8 therefore takes a **kernel source change**, not a config
change: give the symbol a prompt so it can be cleared, change its default, or drop it — which is
what a BSP does implicitly when it backports a newer binder driver onto the older base. Both sides
then move together, because libbinder compares for exact equality, so it is a coordinated kernel
and userspace change rather than a rolling one. A platform that makes that move has one protocol
for its whole life, and every build on it takes `BINDER_IPC_32BIT=OFF`.

Read the kernel's resolved `.config`, not its `defconfig`. The defconfig is an input: config
fragments and Kconfig defaults can set or clear the symbol without it appearing there. In a Yocto
build the resolved config is reachable at `${STAGING_KERNEL_BUILDDIR}/.config` via
`do_configure[depends] += "virtual/kernel:do_shared_workdir"`. Where no kernel config is in scope,
state the switches explicitly rather than letting the build guess.

A defconfig that says nothing about the option is ambiguous, and it is the case to watch. Silence
means one of two opposite things: on a stock kernel at 4.17 or older the symbol exists and
`default y` applies, so the kernel serves protocol 7; on a kernel carrying a newer binder driver —
common on vendor BSPs, which backport it onto older bases — the symbol does not exist at all and
the kernel serves protocol 8. The defconfig looks identical either way.

So a defconfig cannot tell you what a platform runs, whatever it says or omits. Resolve it, or ask
the device:

```sh
zcat /proc/config.gz | grep ANDROID_BINDER      # needs CONFIG_IKCONFIG_PROC=y
grep ANDROID_BINDER /boot/config-"$(uname -r)"  # distro kernels
grep ANDROID_BINDER .config                     # the kernel build tree
```

`/proc/config.gz` exists only when the kernel was built with `CONFIG_IKCONFIG_PROC=y`, which many
embedded kernels omit — fall through to the other two, or ask whoever supplies the kernel. Read the
result as three states, not two: `=y` is protocol 7, `# ... is not set` is protocol 8, and the
symbol being **absent entirely** is also protocol 8 — it means the kernel has no such option.

On a running device the userspace answer is in the library itself, which is worth knowing because
it is the side that has to match:

```sh
nm -DC /usr/lib/libbinder.so | grep ipcSetDataReference
# ... unsigned long long const* ...  => binder_size_t is 64-bit => protocol 8
# ... unsigned int const* ...        => binder_size_t is 32-bit => protocol 7
```

## Specifying this to a platform vendor

State the protocol the platform runs. Do not hand over a list of switches: the kernel and the
userspace take different ones, and a vendor given a flat list can apply the userspace switch
without the kernel change, which is the half-migration that produces the boot failure.

| Who | What they are told | What they set |
| --- | --- | --- |
| Kernel / BSP owner | the protocol this platform serves | `CONFIG_ANDROID_BINDER_IPC_32BIT`, explicitly, in every 32-bit defconfig |
| Anyone building against libbinder | derive from that kernel | nothing by hand — the build reads the kernel |

A rebuild is obliged for everything on a platform that links libbinder if and only if that
platform's kernel protocol changes. Platforms already serving protocol 8 change nothing.

That obligation is enforced by the build rather than by agreement: a build that derives the
protocol from the kernel produces the matching library on its own, and a kernel and userspace that
have drifted apart fail at build time naming both values instead of at boot on a device.

## Standardising on protocol 8

Everything above describes how to carry two protocols correctly. The alternative is to carry one,
and it is the stronger position: agree protocol 8 across every platform, and the class of failure
this document exists for stops being reachable.

The case for it:

**Protocol 7 buys nothing that is wanted.** Upstream's own description is that it exists to support
Android user-space at 4.4 and earlier, and that enabling it breaks newer user-space. It is a
compatibility shim for something no RDK platform runs.

**It costs the ability to mix.** Its 32-bit wire fields cannot carry a 64-bit pointer, so a
protocol-7 platform can never introduce a 64-bit process — not a vendor layer, not a single
service. Protocol 8 leaves that door open at no cost, including on a platform that is entirely
32-bit today.

**It is already the majority position.** Every 64-bit kernel serves protocol 8 because the option
cannot be set. Every kernel from 4.18 serves it because the option was removed. A vendor BSP that
backports a newer binder driver onto an older base serves it too, since the backported driver has
no such option. Protocol 7 survives only on a stock kernel at 4.17 or older that has not opted out
of a default.

**A 32-bit platform on an old kernel can run it.** This is the assumption worth checking before
concluding a legacy platform is stuck: protocol 8 needs 64-bit *fields*, not a 64-bit anything.
An armv7l platform on a 4.9 kernel runs protocol 8 with a 32-bit userspace, one 32-bit
`libbinder.so`, and no 64-bit process anywhere.

**One protocol removes the switch as a decision.** With every platform on 8, `BINDER_IPC_32BIT` is
never chosen by anyone: the derivation reads the kernel and confirms what is already true, and its
only remaining job is to fail the build if a platform ever drifts. The matrix in this document
collapses to a single row.

What it takes is agreement rather than engineering — every platform owner, and every party shipping
a binary that opens `/dev/binder`, on the same protocol. Platforms already serving protocol 8 need
no change at all, so the work is confined to those still on 7, and the first task is finding out
which those are.

### What protocol 8 costs

Protocol 8 widens the per-call metadata and nothing else. From the UAPI:

| Structure | Fields that grow 4 → 8 bytes | Cost |
| --- | --- | --- |
| `binder_transaction_data` | `target.ptr`, `cookie`, `data_size`, `offsets_size`, `buffer`, `offsets` | ~24 bytes per call, fixed |
| `flat_binder_object` | `binder`, `cookie` | 8 bytes per binder object passed |
| the offsets array | each entry is a `binder_size_t` | 4 bytes per binder object passed |

**The transaction payload does not widen.** The `data_size` bytes of a transaction are serialised by
the generated bindings at explicit widths — `writeInt32` writes four bytes, `writeInt64` writes
eight, a string is UTF-16 with a 32-bit length — and the protocol number does not reach any of it.
A 32-bit process sends an `int32` as four bytes at either protocol.

There is no per-datum conversion either. A 32-bit process placing a pointer in a 64-bit field
zero-extends it: one additional store of a zero word, not a pass over the data.

So a call passing no binder objects carries about 24 extra bytes, in one small structure copied
once by the `ioctl`; a call passing two object references carries about 48. Set against the
syscall, the copy of the payload itself and the scheduler round trip, that is the smaller term.

A 32-bit userspace on a 32-bit kernel also crosses no translation layer at all — both sides compile
the same structure layout. The kernel's compat path exists for a 32-bit process on a 64-bit kernel,
and handles the ioctl ABI rather than the protocol.

This is a structural account of what changes, not a measurement. A platform wanting a number should
benchmark its own workload.

## Moving a platform to protocol 8

For a 32-bit platform at 4.17 or older currently serving protocol 7:

1. **Change the kernel, not the defconfig.** The symbol is prompt-less on a stock 4.17-or-older
   kernel, so `# CONFIG_ANDROID_BINDER_IPC_32BIT is not set` in a defconfig or fragment is
   discarded and `default y` is recomputed. Give the symbol a prompt so it becomes settable —
   `tests/qemu/patches/linux-4.9-binder-ipc32-prompt.patch` is that one-line change, and keeps
   `default y` so no existing configuration changes meaning — then add the "is not set" line,
   which now takes effect. Taking the newer binder driver works too, since it drops the symbol
   altogether. A platform already carrying a patch that re-adds the option **with** a prompt can
   clear it from the defconfig directly.
2. **Rebuild the kernel**, and confirm from the resolved `.config` rather than the defconfig. This
   step is what catches a defconfig edit that looked right and did nothing.
3. **Rebuild everything on the platform that links libbinder** — servicemanager, middleware,
   vendor implementations — in the same drop. With the protocol derived from the kernel this needs
   no switch changes; the builds follow the kernel.

Settle one question before starting: is everything on the platform that opens `/dev/binder` built
from source in the pipeline, or does any of it arrive prebuilt? A prebuilt protocol-7 binary that
cannot be rebuilt holds the whole platform at protocol 7, because the version check admits no
mixed state.

The change lands as a flag day. libbinder compares the versions for exact equality when it opens
the driver, so there is no interim in which some processes have moved and others have not.

## Userspace bitness, on either kernel

**Both 32-bit and 64-bit kernels are supported**, and the kernel's bitness does not by itself
change the userspace build. A 64-bit kernel serves protocol 8 and runs 32-bit userspace over its
compat path; a 32-bit kernel serves protocol 8 too, once the Kconfig option is out of the way at
4.17 and older.

**Recommended: 32-bit userspace for both roles, on either kernel.** The switches are then identical
everywhere, and the two builds are the same build:

```text
-DTARGET_LIB32_VERSION=ON -DBINDER_IPC_32BIT=OFF
```

**The protocol is a property of the platform; the bitness is a property of the role.** There is one
kernel, so it serves one protocol, and every role must speak it. Roles may differ in ELF class;
they never differ in protocol.

### The 64-bit vendor variant

A 64-bit vendor layer alongside 32-bit middleware, on a 64-bit kernel, is supported. Protocol 8
exists for exactly that mixture, AIDL primitives are fixed-width so parcels are bitness-independent,
and the role mounts already keep each side's interface libraries apart. What it obliges is
everything that is *not* an IPC surface:

- **Every in-process library both layers use, in both ELF classes.** That is the whole VSI set —
  graphics (EGL/GLES), wifi, bluetooth, linuxinput, filesystem — plus every shared OSS library.
- **Vendor prebuilts available 64-bit.** The GPU userspace driver, the CDM, and vendor codec
  libraries are normally shipped as binaries in one ELF class. If the GPU blob is 32-bit only, a
  64-bit vendor layer cannot do graphics at all.
- **Every shared-memory layout explicitly fixed-width and padded.** A descriptor crosses the
  boundary safely; the layout behind it does not. A control block using `size_t`, `long`, a pointer
  or natural alignment is read differently by a 32-bit and a 64-bit peer, and corrupts silently
  rather than failing.

**Take it only where the SoC vendor supplies a complete 64-bit stack.** On an older or low-cost
SoC that is rarely the case, and 32-bit userspace throughout is the configuration to build. The
decision is set by what the vendor can supply, not by the kernel.

## Platform combinations

Both kernel bitnesses are supported. Middleware is 32-bit throughout, and the recommended vendor
layer is 32-bit as well, so on every supported platform the two roles build identically and the
only variable left is whether the kernel is old enough to still serve protocol 7.

| Platform | Kernel | MW | Vendor | Protocol | MW build | Vendor build |
| --- | --- | --- | --- | --- | --- | --- |
| Legacy all-32-bit | 32-bit, ≤ 4.17, option `=y` | 32-bit | 32-bit | **7** | `LIB32=ON` `IPC32=ON` | same as MW |
| 32-bit kernel at protocol 8 | 32-bit, option unset or absent — every kernel ≥ 4.18, and any older one whose config clears it | 32-bit | 32-bit | **8** | `LIB32=ON` `IPC32=OFF` | same as MW |
| **64-bit kernel — recommended** | 64-bit | 32-bit | 32-bit | **8** | `LIB32=ON` `IPC32=OFF` | same as MW |
| 64-bit kernel, 64-bit vendor | 64-bit | 32-bit | 64-bit | **8** | `LIB32=ON` `IPC32=OFF` | `LIB64=ON` `IPC32=OFF` |
| All-64-bit | 64-bit | 64-bit | 64-bit | **8** | `LIB64=ON` `IPC32=OFF` | same as MW |

The middle three rows are the same userspace build. A 64-bit kernel changes nothing about it: the
32-bit processes run over the kernel's compat path, which is a distinct path in the binder driver
and is worth testing as its own case. The last two rows are the variants that need a full 64-bit
vendor stack behind them — see above for what that obliges.

Four consequences worth stating plainly:

**A 32-bit middleware does not imply protocol 7.** Protocol 7 exists only on a 32-bit kernel at
4.17 or older with the option set. On every other platform — including every 64-bit kernel — a
32-bit middleware runs **protocol 8** over the kernel's compat path. Protocol 8 is the default on
every toolchain, so a middleware build inherits the right protocol everywhere except the legacy
platform, which states `-DBINDER_IPC_32BIT=ON` instead.

**Nor does the kernel version imply it.** Being 32-bit at 4.17 or older is what makes protocol 7
possible, not what makes it apply — the first two rows are the same kernel version with different
configs. A vendor BSP that backports a newer binder driver onto an older base drops the option
entirely, so a 32-bit 4.9 kernel lands in either row and only its resolved config says which. Two
devices on the same silicon and the same kernel version can sit in different rows.

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

Row **A** is the one that must state its switch. Protocol 8 is the default on every toolchain, so
rows B and C are what a build inherits without asking, and only the legacy platform overrides it.
Bitness follows userspace;
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
the protocols interoperate, and once with neither set, exercising what the build derives from the
toolchain alone.

| Kernel | Arch | Protocol | Switches | Result |
| --- | --- | --- | --- | --- |
| 4.9.337-ipc32 | i386 | 7 | explicit | PASS — `servicemanager round-trip 41->42` |
| 4.9.337-ipc32 | i386 | 7 | derived | PASS — derives 8, as documented |
| 4.9.337-i386 | i386 | 8 | explicit | PASS — `servicemanager round-trip 41->42` |
| 4.9.337-i386 | i386 | 8 | derived | PASS — `servicemanager round-trip 41->42` |
| 5.4.290 | x86_64 | 8 | explicit | PASS — `servicemanager round-trip 41->42` |
| 5.4.290 | x86_64 | 8 | derived | PASS — `servicemanager round-trip 41->42` |
| 5.4.290 | x86_64 kernel, **i386 userspace** | 8 | explicit | PASS — `servicemanager round-trip 41->42` |
| 5.4.290-i386 | i386 | 8 | explicit | PASS — `servicemanager round-trip 41->42` |
| 5.4.290-i386 | i386 | 8 | derived | PASS — `servicemanager round-trip 41->42` |
| 5.15.148 | x86_64 | 8 | explicit | PASS — `servicemanager round-trip 41->42` |
| 5.15.148 | x86_64 | 8 | derived | PASS — `servicemanager round-trip 41->42` |
| 5.15.148 | x86_64 kernel, **i386 userspace** | 8 | explicit | PASS — `servicemanager round-trip 41->42` |
| 5.4.290 | x86_64 kernel, **64-bit server + 32-bit client** | 8 | explicit | PASS — `cross-process round-trip 41->42` |
| 5.4.290 | x86_64 kernel, **32-bit server + 64-bit client** | 8 | explicit | PASS — `cross-process round-trip 41->42` |
| 5.15.148 | x86_64 kernel, **64-bit server + 32-bit client** | 8 | explicit | PASS — `cross-process round-trip 41->42` |
| 5.15.148 | x86_64 kernel, **32-bit server + 64-bit client** | 8 | explicit | PASS — `cross-process round-trip 41->42` |

4.9 and 5.4 sit on opposite sides of the 4.18 boundary where the kernel option ceases to exist, so
the pair establishes that protocol selection holds across it. **4.9 appears at both protocols**,
which is the point of carrying it twice: one kernel version serving 7 or 8 depending only on its
Kconfig, which is the pair seen in production on identical silicon. The protocol-8 variant is built
with `patches/linux-4.9-binder-ipc32-prompt.patch`, because a config alone cannot get there.

**The two-process rows are protocol 8 doing the one thing it exists for.** A
32-bit and a 64-bit process transact with each other over one kernel, in both
directions, so a call and its reply each cross the boundary. Every other row is
a single process talking to a proxy back into itself, where both ends are the
same build by construction and no translation happens — which is why the claim
that protocol 8 "supports both 32 and 64bit applications in a mixed
environment" went unexercised until these rows existed. They are also the
transport half of a 64-bit vendor layer with 32-bit middleware; what such a
platform additionally owes is in **Userspace bitness, on either kernel** above.

**The single-bitness mixed rows are the recommended configuration on a 64-bit platform**, and they exercise the
binder driver's compat path — a 32-bit process against a 64-bit kernel — which is distinct code
from both native pairings. The userspace is the same `(i386, protocol 8)` build the 32-bit-kernel
rows use, booted against a 64-bit kernel, so the pairing costs a boot rather than another build.

**The derived row on the protocol-7 kernel is an assertion that derivation is wrong there.**
Protocol 8 is the default on every toolchain, so derivation cannot reach protocol 7 — which is
deliberate: bitness cannot select the protocol, so a derived default has to be wrong somewhere, and
the rare, shrinking case is the one that should have to state its switch. Every other derived row
now simply passes. The harness asserts the legacy mismatch rather than reporting it as a failure,
and fails hard if derivation ever reaches protocol 7 on its own, because that would mean this
guidance had gone stale.

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
