out/
# Linux Binder IDL — AI Agent Instructions

## Project Architecture

- **Purpose:** Port Android 13 Binder IPC (AOSP tag `android-13.0.0_r74`) to Linux for embedded/IoT, with strict separation between *target runtime* (for devices) and *host tools* (for codegen, never shipped).
- **Major outputs:**
  - `out/target/`: Binder runtime libraries (e.g., `libbinder.so`, `servicemanager`) for ARM/embedded
  - `out/host/`: AIDL compiler tools (`aidl`, `aidl-cpp`) for x86_64 build host
- **AIDL codegen is *offline only*:** Architecture team generates C++ from `.aidl` using host tools, commits generated code. *Production builds never run codegen or ship host tools.*
- **Two-phase build design:** Core SDK (Android libs + servicemanager) is built once; AIDL compiler reuses these libs instead of rebuilding them.
- **Source management:** AOSP sources in `android/` cloned by `clone-android-binder-repo.sh`, patched via `patches/*.patch` - **never manually edit `android/` contents**.

## Build & Workflow Patterns

### Developer/Architecture Team (Wrapper Scripts)

- `build-linux-binder-aidl.sh`: Build target runtime (default: 64-bit, override with `TARGET_LIB32_VERSION=ON`)
  - Also builds host AIDL by default; use `no-host-aidl` to skip if already available
  - Respects Yocto environment: `CC`, `CXX`, `CFLAGS`, `CXXFLAGS`, `LDFLAGS`
  - Automatically passes these to CMake as `CMAKE_C_COMPILER`, `CMAKE_CXX_COMPILER`, `CMAKE_C_FLAGS`, etc.
- `build-aidl-generator-tool.sh`: Build host AIDL compiler (for codegen only)
- `build-binder-example.sh`: Build and test FWManager IPC example
- All scripts support both command styles: `clean` or `--clean`, `help` or `--help`

### Production/Yocto (Direct CMake)

**Critical:** *Never* use wrapper scripts in Yocto/BitBake recipes. Call CMake directly:

```bash
cmake -S . -B build-target \
  -DCMAKE_C_COMPILER=arm-linux-gnueabihf-gcc \
  -DCMAKE_CXX_COMPILER=arm-linux-gnueabihf-g++ \
  -DBUILD_HOST_AIDL=OFF \
  -DTARGET_LIB32_VERSION=ON \
  -DCMAKE_INSTALL_PREFIX=/usr/local
```

Required variables: `BUILD_HOST_AIDL=OFF`, and **one of** `TARGET_LIB64_VERSION=ON` or `TARGET_LIB32_VERSION=ON`.

### AIDL Code Generation Workflow

1. Architecture team builds AIDL compiler: `./build-aidl-generator-tool.sh`
2. Generate C++ from `.aidl`: `cd example && ./generate_cpp.sh` (use `clean` to regenerate)
3. Commit generated `.cpp`/`.h` files to `example/stable/generated/FWManager/`
4. Production builds compile pre-generated C++ only (no runtime codegen)

### API Versioning & Dependencies

- Python tools in `host/` manage interface versions: `aidl_ops.py`, `aidl_interface.py`, `aidl_api.py`
- Usage: `./host/aidl_ops.py -u|-f|-g <interface-name>` (update-api, freeze-api, generate-source)
- Dependency tree generation: `./host/aidl_ops.py -a` (for build ordering)
- Interface definitions: `interface.yaml` or `interface.json` in interface directories

## Key Conventions & Patterns

### CMake & Build System

- **No system headers:** CMake explicitly disables `/usr/include` (lines 140+ in CMakeLists.txt); only uses Android headers from `android/`
- **AOSP warning suppression:** All AOSP code warnings suppressed via `-w` and specific `-Wno-*` flags (lines 90–110)
- **Separate build trees:** `build-host/` for AIDL compiler, `build-target/` for runtime libs (never mix)
- **Build environment detection:** CMake auto-detects Yocto via `OECORE_*` environment variables (lines 145–150)
- **AidlGenerator macro:** CMakeLists.txt defines macro for generating stubs/proxies (line 242+); used by examples but not production
- **Default architecture:** 64-bit auto-detected unless `TARGET_LIB32_VERSION=ON` explicitly set (line 172)

### Source Code Management

- **AOSP sources:** Cloned by `clone-android-binder-repo.sh` from Google repos with tag `android-13.0.0_r74`
- **Patches applied automatically:** `patches/*.patch` files modify AOSP code during clone (aidl.patch, core.patch, libbase.patch, logging.patch, native.patch)
- **Never edit `android/` directly:** All modifications must go through patches; `android/` directory is gitignored
- **Re-clone to update patches:** Run `./clone-android-binder-repo.sh` again to apply new patch changes

### File Organization

- `android/`: AOSP sources (aidl, core, native, libbase, logging, fmtlib, googletest) - cloned, never modified directly
- `patches/*.patch`: Local changes to AOSP code, applied during `clone-android-binder-repo.sh`
- `host/`: Python tooling for interface versioning (architecture team only)
  - `aidl_ops.py`: Main CLI for update-api, freeze-api, generate-source operations
  - `aidl_interface.py`, `aidl_api.py`: Interface version management
  - `interface-update.py`: Batch interface updates
- `example/FWManager/`: Reference IPC example with `.aidl` sources and generated C++
  - `FWManager/aidl/`: Source `.aidl` files
  - `stable/generated/FWManager/`: Committed generated code (production builds use this)
  - `generate_cpp.sh`: Script showing AIDL invocation patterns
- `out/target/`: Installed target libraries/binaries
- `out/host/`: Installed AIDL compiler tools
- `build-*/generated/`: Temporary generated files (gitignored, not committed)
- `tools/`: Utility C programs (e.g., BinderDevice.c for device creation)

### Kernel & Runtime Requirements

- **Kernel version:** 5.16+ with `CONFIG_ANDROID_BINDER_IPC=y`
- **32-bit userspace on 64-bit kernel:** Common in embedded; requires `CONFIG_ANDROID_BINDER_IPC_32BIT=y` in kernel
- **Binder device:** `/dev/binder` must exist (via binderfs or static device node)
- **Servicemanager:** Must run before any binder clients start; use systemd service in production
- **Systemd service:** `SYSTEMD_AUTO_ENABLE=enable` in Yocto ensures auto-start on boot

### Cross-Compilation & Architecture

- **Native builds (no env vars):** Script auto-detects system GCC - just run `./build-linux-binder-aidl.sh`
- **Cross-compilation (Yocto/embedded):** Set environment variables before invoking scripts:
  ```bash
  export CC=arm-linux-gnueabihf-gcc
  export CXX=arm-linux-gnueabihf-g++
  export CFLAGS="--sysroot=/path/to/sysroot -march=armv7-a"
  export CXXFLAGS="--sysroot=/path/to/sysroot -march=armv7-a"
  export LDFLAGS="--sysroot=/path/to/sysroot"
  export TARGET_LIB32_VERSION=ON
  ./build-linux-binder-aidl.sh
  ```
- **Direct CMake:** Pass compiler and flags explicitly (see Production/Yocto section above)
- `TARGET_LIB32_VERSION=ON` for 32-bit ARM/i686 targets
- `TARGET_LIB64_VERSION=ON` for 64-bit aarch64/x86_64 targets (default auto-detected)
- Never set both 32-bit and 64-bit flags simultaneously
- **32-bit userspace on 64-bit kernel:** Common in embedded systems for memory efficiency
  - Build with `TARGET_LIB32_VERSION=ON` even if kernel is 64-bit
  - Requires kernel config `CONFIG_ANDROID_BINDER_IPC_32BIT=y`
  - Match build to *userspace* architecture, not kernel architecture

## Testing & Validation

- **Quick validation:** `./quick_test.sh` (~5-10 min) - validates clone, build, outputs
- **Comprehensive test:** `./test_build.sh` (~10-20 min) - full validation suite with zero-warnings check
- **Example IPC test:** `./build-binder-example.sh` - builds FWManager service/client, tests binder IPC
- **Clean builds:** Add `clean` to any build script (e.g., `./build-linux-binder-aidl.sh clean`)
- **Runtime testing:** Requires Linux 5.16+ with binder; see BUILD.md §"Testing" for Vagrant/KVM setup

## Common Pitfalls

- **Never** build or ship host AIDL tools in production Yocto builds
- **Never** use wrapper scripts in BitBake recipes (use direct CMake invocation)
- **Never** use both `TARGET_LIB32_VERSION` and `TARGET_LIB64_VERSION` simultaneously
- **Never** allow `/usr/include` in compile commands (CMake explicitly disables this)
- **Never** manually edit files in `android/` directory - use patches instead
- **Always** commit AIDL-generated C++ to `stable/generated/`; never generate at production build time
- **Always** set `CC`/`CXX`/`CFLAGS`/`CXXFLAGS`/`LDFLAGS` for cross-compilation (Yocto sets these automatically)
- **Always** ensure CFLAGS/CXXFLAGS/LDFLAGS include sysroot when cross-compiling
- **Native builds:** Leave CC/CXX unset to use system GCC (CMake auto-detects)
- **Remember** servicemanager must start before binder clients (systemd dependency ordering)
- **Remember** to re-run `clone-android-binder-repo.sh` after modifying any `.patch` files

## Reference Files

- [BUILD.md](../BUILD.md): Authoritative build guide - Yocto integration, CMake variables, runtime setup
- [README.md](../README.md): Quick start, build commands, output structure
- [example/generate_cpp.sh](../example/generate_cpp.sh): AIDL codegen workflow reference
- [host/aidl_ops.py](../host/aidl_ops.py): Interface versioning CLI (run with `--help`)
- [CMakeLists.txt](../CMakeLists.txt): Core build logic - see lines 90–110 (warnings), 240+ (AidlGenerator)
- [clone-android-binder-repo.sh](../clone-android-binder-repo.sh): AOSP source management and patching
- [CHANGELOG.md](../CHANGELOG.md): Version history - latest is 1.1.0 with AIDL versioning support

---
**AI agents:** Follow these conventions strictly. When in doubt:
1. Check [BUILD.md](../BUILD.md) for build system and Yocto integration
2. Check [README.md](../README.md) for quick start and workflow
3. Read script `--help` output for usage patterns
4. Never modify `android/` contents directly - use patches in `patches/` directory
