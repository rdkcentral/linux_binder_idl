# Binder Protocol Switch Matrix

Which switches to build the binder library with, for which target kernel.

## The failure this prevents

The binder wire protocol is fixed at compile time on **both** sides. The kernel's is set by
`CONFIG_ANDROID_BINDER_IPC_32BIT`; the library's by `BINDER_IPC_32BIT`. libbinder compares them
for exact equality when it opens the driver, and there is no fallback — the process terminates:

```
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

The same applies to the public C++ headers this project installs. `binder/Parcel.h` switches
`binder_size_t` and the `mObjects` layout on `BINDER_IPC_32BIT`, so a consumer that compiles
without the define sees a different `Parcel` than libbinder exports. Targets that link the
`binder` CMake target inherit it; anything built outside this project's CMake must define it.

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

## The switches to build with

| Configuration | Toolchain | Protocol | Switches |
| --- | --- | --- | --- |
| **A** — Legacy all-32-bit<br>32-bit kernel ≤ 4.17 with the option set | 32-bit | 7 | `-DTARGET_LIB32_VERSION=ON`<br>`-DBINDER_IPC_32BIT=ON` |
| **B** — Mixed, 32-bit MW<br>32-bit userspace on a protocol-8 kernel | 32-bit | 8 | `-DTARGET_LIB32_VERSION=ON`<br>`-DBINDER_IPC_32BIT=OFF` |
| **C** — All-64-bit<br>any protocol-8 kernel | 64-bit | 8 | `-DTARGET_LIB64_VERSION=ON`<br>`-DBINDER_IPC_32BIT=OFF` |

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
| 5.15.148 | x86_64 | 8 | explicit | PASS — `servicemanager round-trip 41->42` |
| 5.15.148 | x86_64 | 8 | derived | PASS — `servicemanager round-trip 41->42` |

The negative cases are the point of the harness: a protocol-8 userspace against the protocol-7
kernel fails, reproducing the field error verbatim in the guest console, and a `:ipc32` variant on
5.4 is rejected up front with `needs a 4.9-4.17 kernel — CONFIG_ANDROID_BINDER_IPC_32BIT was
removed in 4.18`.

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
