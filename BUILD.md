# Linux Binder Build Guide

## Build Structure

This repository provides **two separate builds**:

1. **Host Tools** (`out/host/`) - AIDL compiler tools for code generation
2. **Target Libraries** (`out/target/`) - Binder runtime libraries for embedded devices

```bash
out/
├── host/              # Host tools (x86_64 build machine)
│   └── bin/
│       ├── aidl       # AIDL compiler
│       └── aidl-cpp   # C++ AIDL compiler
└── target/            # Target libraries (ARM/device architecture)
    ├── bin/
    │   └── servicemanager
    ├── lib/
    │   ├── libbinder.so
    │   ├── liblog.so
    │   └── ...
    └── include/       # Binder headers
```

## Prerequisites

- Ubuntu 22.04 LTS (or similar)
- CMake 3.22.1 or later
- GCC 11.2.0 or later (GCC 9.4.0 minimum)
- For cross-compilation: ARM toolchain (e.g., `arm-linux-gnueabihf-gcc`)

## Building Host Tools

Host tools run on your **build machine** (typically x86_64) to generate code from AIDL interfaces.

```bash
./build-aidl-generator-tool.sh

# Clean build (removes build-host/ and out/host/ first)
./build-aidl-generator-tool.sh --clean

# Show help
./build-aidl-generator-tool.sh --help
```

**Output:**

- `out/host/bin/aidl` - AIDL compiler
- `out/host/bin/aidl-cpp` - C++ AIDL compiler

**Compiler Selection:**
Uses system default `gcc/g++`. Override if needed with `HOST_CC`/`HOST_CXX`:

```bash
export HOST_CC=gcc-11
export HOST_CXX=g++-11
./build-aidl-generator-tool.sh
```

## Building Target Libraries

Target libraries run on your **embedded device** (typically ARM).

### Native Build (x86_64 target)

For local testing or x86_64 targets using system GCC:

```bash
./build-linux-binder-aidl.sh

# Clean build (removes build-target/ and out/target/ first)
./build-linux-binder-aidl.sh clean

# Show help
./build-linux-binder-aidl.sh help
```

**Note:**
- This script builds the host AIDL generator tool by default so the target build can generate stubs/proxies.
- Use `no-host-aidl` if you already have `out/host/bin/aidl` available.
- When CC/CXX are **not set**, CMake automatically uses system compiler (gcc/g++ from build-essential).

### Cross-Compilation (ARM target)

For ARM embedded devices with cross-compiler and sysroot:

```bash
export CC=arm-linux-gnueabihf-gcc
export CXX=arm-linux-gnueabihf-g++
export CFLAGS="--sysroot=/path/to/sysroot -march=armv7-a -mfpu=neon"
export CXXFLAGS="--sysroot=/path/to/sysroot -march=armv7-a -mfpu=neon"
export LDFLAGS="--sysroot=/path/to/sysroot"
export TARGET_LIB32_VERSION=ON  # For 32-bit ARM
./build-linux-binder-aidl.sh
```

**Note:** The script respects all standard Yocto environment variables:
- `CC` / `CXX` - Cross-compiler toolchain
- `CFLAGS` / `CXXFLAGS` - Compiler flags (sysroot, architecture-specific flags)
- `LDFLAGS` - Linker flags (sysroot, library paths)

These are automatically passed to CMake as `CMAKE_C_COMPILER`, `CMAKE_CXX_COMPILER`, `CMAKE_C_FLAGS`, `CMAKE_CXX_FLAGS`, and `CMAKE_*_LINKER_FLAGS`.

**Output:**

- `out/target/lib/libbinder.so` - Core binder library
- `out/target/lib/liblog.so`, `libbase.so`, etc. - Support libraries
- `out/target/bin/servicemanager` - Binder service manager
- `out/target/include/` - Headers for building binder clients/services

## Build Options

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `CC` | C compiler | System default |
| `CXX` | C++ compiler | System default |
| `CFLAGS` | C compiler flags (sysroot, arch flags) | None |
| `CXXFLAGS` | C++ compiler flags | None |
| `LDFLAGS` | Linker flags | None |
| `BUILD_TYPE` | `Debug` or `Release` | `Release` |
| `TARGET_LIB32_VERSION` | Build 32-bit target | `OFF` |

### Examples

**Native build (system GCC):**

```bash
# Uses system default gcc/g++ - no environment variables needed
./build-linux-binder-aidl.sh
```

**Debug build for host tools:**

```bash
BUILD_TYPE=Debug ./build-aidl-generator-tool.sh
```

**Cross-compile: 32-bit ARM target with sysroot:**

```bash
export CC=arm-linux-gnueabihf-gcc
export CXX=arm-linux-gnueabihf-g++
export CFLAGS="--sysroot=/opt/poky/sysroots/armv7ahf-neon -march=armv7-a"
export CXXFLAGS="--sysroot=/opt/poky/sysroots/armv7ahf-neon -march=armv7-a"
export LDFLAGS="--sysroot=/opt/poky/sysroots/armv7ahf-neon"
export TARGET_LIB32_VERSION=ON
./build-linux-binder-aidl.sh
```

## Integration with Yocto/Bitbake

### Production Build (CMake Direct)

**Production build systems (Yocto/BitBake) MUST call CMake directly** with explicit variables. The wrapper scripts (`build-*.sh`) are convenience tools for developers and architecture team members only - they are NOT suitable for production recipes.

**Production builds only require TARGET libraries** - the AIDL compiler is used offline by the architecture team (using `./build-aidl-generator-tool.sh` for convenience) to generate interface code, which is then committed to the repository.

**BitBake Recipe Example:**

```bitbake
inherit cmake

# Production recipe - build binder runtime libraries only
DEPENDS = ""

EXTRA_OECMAKE = " \
    -DBUILD_HOST_AIDL=OFF \
    -DTARGET_LIB64_VERSION=${@bb.utils.contains('TUNE_FEATURES', 'aarch64', 'ON', 'OFF', d)} \
"

do_install() {
    cmake --install ${B} --prefix ${D}${prefix}
}

FILES_${PN} += "${libdir}/lib*.so*"
FILES_${PN}-dev += "${includedir}/*"
```

**Key Points:**

- **Production builds**: Only build target runtime libraries (`BUILD_HOST_AIDL=OFF`, SDK built by default)
- **No AIDL compiler needed**: Architecture team generates C++ code offline using AIDL compiler
- **Pre-generated code committed**: All AIDL-generated C++ files are in source control
- **No code generation at build time**: Production builds compile pre-generated C++ only
- **Servicemanager startup**: Systemd service auto-starts on boot via `SYSTEMD_AUTO_ENABLE`

### CMake Variables Reference

**When to use what:**
- **Production (Yocto/BitBake)**: Call CMake directly with explicit variables (documented below)
- **Development/Architecture Team**: Use wrapper scripts for convenience (see [Manual/Development Build](#manualdevelopment-build-wrapper-scripts) section)

The following tables list CMake variables for **direct CMake invocation in production build systems**. Wrapper scripts handle these automatically - developers and architecture team members do NOT need to configure these manually.

#### Required Configuration Variables

| Variable | Description | Default | Required? |
|----------|-------------|---------|-----------|
| `BUILD_HOST_AIDL` | Build host AIDL compiler (architecture team only) | `ON` | **Required** - Set to `OFF` for production |

#### Architecture Selection (One Required)

| Variable | Description | Default | Notes |
|----------|-------------|---------|-------|
| `TARGET_LIB64_VERSION` | Build 64-bit libraries | Auto-detect | Use for aarch64, x86_64 |
| `TARGET_LIB32_VERSION` | Build 32-bit libraries | `OFF` | Use for armhf, i686 |

**Note:** Set **either** `TARGET_LIB64_VERSION=ON` **or** `TARGET_LIB32_VERSION=ON`, not both.

**Important - 32-bit Userspace on 64-bit Kernel:**

Many embedded systems run 32-bit userspace applications on a 64-bit kernel for memory efficiency. In this configuration:

- **Kernel**: 64-bit (e.g., aarch64 kernel)
- **Userspace**: 32-bit (e.g., armhf libraries and applications)
- **Build Configuration**: Use `TARGET_LIB32_VERSION=ON` to build 32-bit binder libraries
- **Kernel Requirement**: Kernel must have `CONFIG_ANDROID_BINDER_IPC_32BIT=y` enabled

The 64-bit kernel handles syscall translation automatically. Build the userspace libraries to match your **userspace architecture**, not the kernel architecture.

#### Installation Paths (All Optional)

| Variable | Description | Default | Notes |
|----------|-------------|---------|-------|
| `CMAKE_INSTALL_PREFIX` | Installation root directory | `/usr/local` | Yocto uses `${prefix}` or `${D}${prefix}` |

**Important:** CMake **does not** use separate `TARGET_DIRECTORIES` or similar output path variables. The build system automatically places output in:
- Build artifacts: `${CMAKE_BINARY_DIR}` (e.g., `build-target/`)
- Installed files: `${CMAKE_INSTALL_PREFIX}` (e.g., `/usr/local` or Yocto staging)

#### Complete CMake Invocation Examples (Yocto/Production)

These examples show **direct CMake usage for production build systems** (Yocto/BitBake) targeting ARM embedded devices. For development/testing, use the wrapper scripts instead (see below).

**Yocto/Production: Target Build (64-bit ARM - aarch64):**

```bash
# Direct CMake invocation for Yocto/BitBake recipes targeting aarch64 devices
cmake -S . -B build-target \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
    -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
    -DBUILD_HOST_AIDL=OFF \
    -DTARGET_LIB64_VERSION=ON \
    -DCMAKE_INSTALL_PREFIX=/usr/local

cmake --build build-target -j$(nproc)
cmake --install build-target
```

**Non-Yocto note:** If you run direct CMake builds outside Yocto and have AIDL
code generation enabled, ensure `out/host/bin/aidl` exists (run
`./build-aidl-generator-tool.sh` first).

**Yocto/Production: Target Build (32-bit ARM - armhf):**

```bash
# Direct CMake invocation for Yocto/BitBake recipes with cross-compilation
# Use case: 32-bit userspace on 64-bit kernel (common in embedded systems)
cmake -S . -B build-target \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=arm-linux-gnueabihf-gcc \
    -DCMAKE_CXX_COMPILER=arm-linux-gnueabihf-g++ \
    -DBUILD_HOST_AIDL=OFF \
    -DTARGET_LIB32_VERSION=ON \
    -DCMAKE_INSTALL_PREFIX=/usr/local

cmake --build build-target -j$(nproc)
cmake --install build-target
```

**Note:** This 32-bit build works on both 32-bit kernels and 64-bit kernels (with `CONFIG_ANDROID_BINDER_IPC_32BIT=y`).

**Direct CMake: Build AIDL Compiler (Architecture Team - Advanced Use Only):**

```bash
# Direct CMake invocation (advanced - most users should use wrapper script below)
cmake -S . -B build-host \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_HOST_AIDL=ON \
    -DCMAKE_INSTALL_PREFIX=/usr/local

cmake --build build-host -j$(nproc)
cmake --install build-host
```

**Note:** Architecture team members should typically use `./build-aidl-generator-tool.sh` instead. The architecture team works **outside** the production build system (Yocto/BitBake) - they build the AIDL compiler locally to generate interface code and manage interface versions. This direct CMake example is only for advanced users who need custom configuration.

#### Minimal Required Variables Summary

For **production builds**, you MUST set these two variables:

1. `-DBUILD_HOST_AIDL=OFF` (exclude AIDL compiler - uses pre-generated C++ code)
2. **One of:** `-DTARGET_LIB64_VERSION=ON` **or** `-DTARGET_LIB32_VERSION=ON`

All other variables have sensible defaults and are optional.

### Manual/Development Build (Wrapper Scripts)

**These scripts are for development and architecture team convenience only.** Production builds (Yocto/BitBake) should call CMake directly as shown in the examples above.

**Wrapper scripts automatically handle:**

- All required CMake variables
- Directory creation
- Android source cloning
- Installation to `out/` directories

**Use Cases:**

- Architecture team building AIDL compiler for code generation
- Developers testing binder functionality locally
- Quick builds without configuring CMake variables manually

**Build AIDL Compiler (Architecture Team):**

```bash
./build-aidl-generator-tool.sh

# Clean build
./build-aidl-generator-tool.sh --clean
```

**Build Target Libraries (Development/Testing):**

```bash
./build-linux-binder-aidl.sh

# Cross-compile for ARM
CC=arm-linux-gnueabihf-gcc CXX=arm-linux-gnueabihf-g++ \
    ./build-linux-binder-aidl.sh

# Clean build
./build-linux-binder-aidl.sh --clean
```

**Important:** Yocto/BitBake recipes must NOT use these wrapper scripts. Use direct CMake invocation instead.

## Clean Builds

Both build scripts support the `--clean` flag:

```bash
# Clean and rebuild host tools
./build-aidl-generator-tool.sh --clean

# Clean and rebuild target libraries
./build-linux-binder-aidl.sh --clean

# Or manually clean specific components:
rm -rf build-host out/host/      # Clean host only
rm -rf build-target out/target/  # Clean target only
rm -rf build-host build-target out/  # Clean everything
```

## Troubleshooting

### Missing kernel headers

The repository includes Android kernel headers in `android/bionic/libc/kernel/`.
If you see "binder.h not found", the CMake configuration is incorrect.

### Cross-compilation fails

Ensure your cross-compiler toolchain is properly configured:

```bash
${CC} --version
${CXX} --version
```

### Libraries not found during linking

The CMake build should be self-contained. If you see missing library errors,
ensure you're building the target SDK (default behaviour).

## Architecture Notes

- **Host tools are architecture-independent** - They generate code, not run on target
- **Target libraries must match userspace architecture** - Build 32-bit libraries for 32-bit userspace, 64-bit for 64-bit userspace
- **32-bit userspace on 64-bit kernel** - Common in embedded systems; use `TARGET_LIB32_VERSION=ON` and ensure kernel has `CONFIG_ANDROID_BINDER_IPC_32BIT=y`
- **No mixing within userspace** - All binder libraries and applications in userspace must be the same bitness (all 32-bit or all 64-bit)
- **Host and target use separate build directories** - Never mix host tool builds with target library builds
- **Kernel headers included** - Self-contained build, no system dependencies

## Runtime Setup and Installation

### Prerequisites for Target Device

#### Kernel Requirements

The target device kernel must have Binder support enabled. Required kernel config:

```kconfig
CONFIG_ANDROID=y
CONFIG_ANDROID_BINDER_IPC=y
CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"
CONFIG_ANDROID_BINDER_IPC_32BIT=y       # REQUIRED for 32-bit userspace (even on 64-bit kernel)
# CONFIG_ANDROID_BINDER_IPC_SELFTEST is not set
CONFIG_ASHMEM=y
CONFIG_ANDROID_BINDERFS=y               # Required for Ubuntu/desktop Linux
```

**Critical: 32-bit Userspace Configuration**

`CONFIG_ANDROID_BINDER_IPC_32BIT=y` is **required** in these scenarios:

- Pure 32-bit system (32-bit kernel + 32-bit userspace)
- Mixed architecture system (64-bit kernel + 32-bit userspace) - **common in embedded systems**

A 64-bit kernel with this option enabled can support both 32-bit and 64-bit userspace applications simultaneously. The kernel handles the necessary syscall translation and data structure compatibility.

**Note:** Some Ubuntu kernels (5.16.20) have SELinux context issues with binder. A patch may be required for `drivers/android/binder.c`.

Refer to: <https://www.kernel.org/doc/html/latest/admin-guide/binderfs.html>

#### Creating Binder Device Nodes

On systems using `binderfs`:

```bash
# Mount binderfs (typically done at boot)
mkdir -p /dev/binderfs
mount -t binder binder /dev/binderfs

# Create binder device
echo binder > /dev/binderfs/binder-control

# Set permissions
chmod 0666 /dev/binderfs/binder

# Create legacy symlink for compatibility
ln -sf /dev/binderfs/binder /dev/binder
```

For systems with static binder device:

```bash
# Device node should exist at /dev/binder
ls -l /dev/binder
# Expected: crw-rw-rw- 1 root root 10, 57 ...
```

### Installing Built Libraries

After building, install to target filesystem:

```bash
# Install to system directories (requires root)
sudo cmake --install build-target --prefix /usr/local

# Or install to staging directory for packaging
cmake --install build-target --prefix ${STAGING_DIR}/usr
```

Installed files:

- Libraries: `/usr/local/lib/lib{binder,utils,log,base,cutils}.so`
- Binaries: `/usr/local/bin/servicemanager`
- Headers: `/usr/local/include/{binder,utils,log,cutils}/`

### Systemd Service Configuration

The Binder `servicemanager` **must be running** before any binder client applications start. In production systems, servicemanager should run as a systemd service that starts automatically on boot.

#### Service Startup Expectations

- **Production (Systemd)**: servicemanager starts automatically on boot when enabled
- **Development/Testing**: servicemanager can be started manually for testing
- **Yocto/Embedded**: Systemd service is installed and auto-enabled via BitBake recipe

#### Service Unit File

Create `/etc/systemd/system/servicemanager.service`:

```ini
[Unit]
Description=Android Binder Service Manager
Documentation=https://source.android.com/docs/core/architecture/hidl/binder-ipc
After=local-fs.target
Before=basic.target

[Service]
Type=simple
ExecStart=/usr/local/bin/servicemanager
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
# Ensure binder device is available
DeviceAllow=/dev/binder rw
DeviceAllow=/dev/binderfs/binder rw

[Install]
WantedBy=multi-user.target
```

#### Enable and Start the Service

```bash
# Reload systemd configuration
sudo systemctl daemon-reload

# Enable service to start automatically on boot
sudo systemctl enable servicemanager.service

# Start service immediately (for current session)
sudo systemctl start servicemanager.service

# Verify service is running
sudo systemctl status servicemanager.service
```

**Important Notes:**

- `systemctl enable` configures the service to start automatically on every boot
- `systemctl start` starts the service immediately in the current session
- After `enable`, the service will start automatically on next reboot
- In Yocto builds, `SYSTEMD_AUTO_ENABLE` handles the enable step automatically

#### Manual Startup (Development/Testing Only)

For development or testing without systemd:

```bash
# Ensure binder device exists
ls -l /dev/binder

# Start servicemanager in background
sudo /usr/local/bin/servicemanager &

# Verify it's running
ps aux | grep servicemanager
```

**Note:** This method is **not recommended for production**. Always use systemd in production environments.

### Runtime Library Path

Client applications need to find binder libraries at runtime:

**Option 1: System library path (recommended for production)**

```bash
# Libraries installed to /usr/local/lib are automatically found
sudo ldconfig
```

**Option 2: LD_LIBRARY_PATH (development only)**

```bash
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
```

**Option 3: Yocto/BitBake (handled automatically)**

- Libraries installed to `${libdir}` are in the standard search path

### Verification

Test the installation:

```bash
# 1. Check servicemanager service status
systemctl status servicemanager.service
# Expected: Active: active (running)

# 2. Verify servicemanager process is running
ps aux | grep servicemanager
# Expected: root ... /usr/local/bin/servicemanager

# 3. Check binder device exists and is accessible
ls -l /dev/binder
# Expected: crw-rw-rw- 1 root root ...

# 4. Verify servicemanager auto-starts on boot
systemctl is-enabled servicemanager.service
# Expected: enabled

# 5. Check for errors in system logs
journalctl -u servicemanager.service -n 50
# Expected: No errors, servicemanager started successfully
```

**Expected Startup Sequence:**

1. System boots and reaches `multi-user.target`
2. Systemd starts servicemanager (if enabled)
3. Servicemanager opens `/dev/binder` device
4. Servicemanager enters main loop waiting for service registrations
5. Binder client applications can now register and communicate

## Yocto/BitBake Recipe Migration

### Updated Recipe Template

Here's the modernized BitBake recipe for the current build system:

```bash
DESCRIPTION = "Android Binder IPC for Linux"
SECTION = "libs"
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=86d3f3a95c324c9479bd8986968f4327"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Source repository
SRC_URI = "git://github.com/your-org/linux_binder_idl.git;protocol=https;branch=main"
SRC_URI += "file://servicemanager.service"

SRCREV = "${AUTOREV}"
S = "${WORKDIR}/git"

# Build dependencies
DEPENDS = ""

# Use CMake
inherit cmake systemd

# CMake configuration - production target build only
EXTRA_OECMAKE = " \
    -DBUILD_HOST_AIDL=OFF \
    -DTARGET_LIB64_VERSION=${@bb.utils.contains('TUNE_FEATURES', 'aarch64', 'ON', 'OFF', d)} \
    -DTARGET_LIB32_VERSION=${@bb.utils.contains('TUNE_FEATURES', 'aarch64', 'OFF', 'ON', d)} \
    -DCMAKE_INSTALL_PREFIX=${prefix} \
"

# Clone Android sources before CMake configuration
do_configure:prepend() {
    cd ${S}
    ${S}/clone-android-binder-repo.sh
}

# Install systemd service
do_install:append() {
    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${WORKDIR}/servicemanager.service ${D}${systemd_unitdir}/system/
}

# Systemd integration
SYSTEMD_SERVICE:${PN} = "servicemanager.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"  # Auto-start on boot

# Package files
FILES:${PN} = " \
    ${libdir}/lib*.so* \
    ${bindir}/servicemanager \
    ${systemd_unitdir}/system/servicemanager.service \
"

FILES:${PN}-dev = " \
    ${includedir}/* \
"

# Allow shared libraries in main package
FILES_SOLIBSDEV = ""

# Skip dev-elf checks (expected for binder libraries)
INSANE_SKIP:${PN} = "dev-deps"
INSANE_SKIP:${PN}-dev = "dev-elf"
```

### Key Changes from Legacy Recipe

**Removed:**

- ❌ `setup-env.sh` sourcing
- ❌ Manual `clone_android_binder_repo` function call
- ❌ `BUILD_ENV_YOCTO` flag (no longer exists)

**Added:**

- ✅ `BUILD_HOST_AIDL=OFF` flag (exclude AIDL compiler from production build)
- ✅ `clone-android-binder-repo.sh` script invocation
- ✅ `TARGET_LIB64_VERSION` / `TARGET_LIB32_VERSION` based on architecture
- ✅ `SYSTEMD_AUTO_ENABLE` for automatic service enablement

**Unchanged:**

- CMake inheritance
- Systemd service installation
- Package file lists

### Creating the Systemd Service File

Create `files/servicemanager.service`:

```ini
[Unit]
Description=Android Binder Service Manager
Documentation=https://source.android.com/docs/core/architecture/hidl/binder-ipc
After=local-fs.target
Before=basic.target
Requires=dev-binder.device
After=dev-binder.device

[Service]
Type=simple
ExecStart=/usr/bin/servicemanager
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=servicemanager

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/dev/binder /dev/binderfs

# Device access
DeviceAllow=/dev/binder rw
DeviceAllow=/dev/binderfs/binder rw

[Install]
WantedBy=multi-user.target
```

### Testing the Yocto Build

```bash
# Build the recipe
bitbake linux-binder-idl

# Check installed files
oe-pkgdata-util list-pkg-files linux-binder-idl

# Test on target device
ssh root@target
systemctl status servicemanager
ls -l /dev/binder
ldd /usr/bin/servicemanager
```
