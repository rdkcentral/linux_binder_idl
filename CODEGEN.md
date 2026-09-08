# Generated C++ Contract

What a consumer of this generator's C++ output may rely on.

This matters beyond the build: `rdk-halif-aidl` commits generated C++ into its
released snapshots, so the shape and stability of that output is part of its
release contract. Its architecture document levies five requirements on this
repository, `BINDER-F-001` to `BINDER-F-005`, tracked in the
[Requirements](#requirements) table below.

For building the generator, see [BUILD.md](BUILD.md). For kernel and wire
protocol selection, see [PROTOCOL.md](PROTOCOL.md).

---

## Invocation

```bash
aidl --lang=cpp --structured --stability=vintf \
     --version=<n> --hash=<hash> --min_sdk_version=<n> \
     -I<import-root> \
     --header_out <dir>/include -o <dir>/src \
     <files>.aidl
```

| Flag | Effect on the output |
|---|---|
| `--lang=cpp` | Selects the C++ backend. The only backend this contract covers. |
| `--structured` | Requires every referenced type to be declared in AIDL. |
| `--stability=vintf` | Marks the interface as a stable vendor interface. |
| `--version=<n>` | Emits `VERSION` and makes `getInterfaceVersion()` return it. Omitted or `0` emits neither. |
| `--hash=<hash>` | Emits `HASH` and makes `getInterfaceHash()` return it. Also governs the cached-hash members in the proxy. `notfrozen` marks a development build. |
| `-I<root>` | Import search root. Every imported type's root must be supplied, including transitive ones. |

---

## What each declaration produces

For an AIDL file declaring `IFoo`, in package `com.example`:

| Artefact | Contains |
|---|---|
| `include/com/example/IFoo.h` | The abstract interface, `DECLARE_META_INTERFACE`, the identity constants, and a `IFooDefault` no-op implementation |
| `include/com/example/BpFoo.h` | The **proxy** — what a caller holds |
| `include/com/example/BnFoo.h` | The **stub** — what an implementer derives from |
| `src/com/example/IFoo.cpp` | The implementations of **both** the proxy and the stub |

A `parcelable`, `union` or `enum` produces its own header and marshalling
translation unit. It does not need binder helpers — see
[Known deviations](#known-deviations).

### Structure of the generated code

The proxy carries per-connection cached identity, guarded by a mutex:

```cpp
class BpFoo : public ::android::BpInterface<IFoo> {
  // ...
private:
  int32_t cached_version_ = -1;
  std::string cached_hash_ = "-1";
  std::mutex cached_hash_mutex_;
};
```

Those members are emitted only when `--hash` is supplied, and the header
includes `<mutex>` under the same condition. The stub carries `onTransact` and
no cached state.

**Proxy and stub implementations share one translation unit.** `IFoo.cpp`
contains both `BpFoo::` and `BnFoo::` definitions, so a consumer that links the
object gets both halves regardless of the role it plays. Measured across
several `rdk-halif-aidl` components, roughly 47% of generated lines are
client-only, 37% server-only and 16% shared marshalling. Neither packaging nor
compiling the sources directly separates them; only emitting `BpFoo.cpp` and
`BnFoo.cpp` separately would.

### Interface identity

`IFoo.h` carries the identity a client uses to decide whether it can talk to a
given server:

| Symbol | Emitted when | Reported by |
|---|---|---|
| `VERSION` | `--version` > 0 | `getInterfaceVersion()` |
| `HASH` | `--hash` non-empty | `getInterfaceHash()` |
| `HASHVALUE` | `--hash` non-empty | — |

Both accessors are per-connection on the proxy and cached after first use.

Consumers are not expected to call them directly. In `rdk-halif-aidl` these
symbols are read by [`halcompat.h`](https://github.com/rdkcentral/rdk-halif-aidl/blob/develop/common/current/halcompat.h),
the client-side helper that applies the era compatibility rules and keeps the
version encoding away from client code — so what this generator emits as
`VERSION` and `HASH` is what decides whether a client may talk to a given
server. The rules themselves are in the
[Versioning Guide](https://github.com/rdkcentral/rdk-halif-aidl/blob/develop/docs/standards/versioning-guide.md).

---

## Determinism

For a **given generator build**, identical AIDL input produces identical
output. Formatting, ordering and naming are all derived from the AIDL.

Across **different generator builds**, output may differ: a change to the
generator changes what it emits, and the same frozen AIDL can then produce
materially different C++. This has happened — before #59, generated `Bp*.h`
files used `std::mutex` without including `<mutex>`, so the same AIDL compiled
for one consumer and not another.

**The output does not record which generator produced it.** A consumer holding
generated C++ cannot determine the generator build behind it, which is what
`BINDER-F-003` asks for.

---

## Requirements

Levied by `rdk-halif-aidl`'s architecture document. Status is against this
repository's `develop`.

| # | Requirement | Status |
|---|---|---|
| BINDER-F-001 | Documentation comments carried from AIDL into generated headers | **Not met** — #28 |
| BINDER-F-002 | Byte-identical output for identical input at a given generator version | **Met** |
| BINDER-F-003 | Generated output identifies the generator version that produced it | **Not met** |
| BINDER-F-004 | Binder helper headers emitted only for interfaces | **Not met** — #29 |
| BINDER-F-005 | Generated code compiles without diagnostics under `-Werror` at C++17 | **Not met** — see below |

---

## Known deviations

Current behaviour that does not meet the contract above. Each is a defect, not
a design choice.

| Deviation | Effect | Issue |
|---|---|---|
| Documentation comments are stripped | Generated headers carry no API documentation, so IDE tooltips are empty and a Doxygen run over the headers yields structure only | #28 |
| `Bn*`/`Bp*` headers emitted for enums and parcelables | Helper headers that no caller or implementer uses | #29 |
| `static constexpr char* HASHVALUE = "…"` in `I*.h` | A string literal bound to `char*` — ill-formed in C++11 and later. GCC warns by default and **errors under `-Werror`**; clang warns under `-Wwritable-strings`. Should be `constexpr const char*` | to raise |
| `static const int32_t VERSION` in `I*.h` | Not implicitly inline in C++17, so ODR-use gives `undefined reference`. `static constexpr` would be correct | to raise |

Consumers building with `-Werror` should treat generated headers as system
includes until the third row is fixed, which suppresses the whole class rather
than this instance.

---

## Surface dump and structural diff

`aidl_ops` classifies the structural difference between two AIDL trees, which
is what lets a consumer decide whether a change is additive or breaking.
Declaration order is ABI — transaction ids and parcel order — so removals,
changes and reorders classify as `breaking`, appends as `major`, and identical
surfaces as `none`. Doc comments are stripped at dump time, so a comment-only
edit produces byte-identical dumps.

See the usage in [README.md](README.md).
