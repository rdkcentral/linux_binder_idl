# Linux Binder IDL

This project aims to build and test the Android Binder for the Linux desktop environment.
The Android 13 AOSP source code is cloned from `Google's` repositories. The Android tag
 is __*android-13.0.0_r74*__, and the code has been modified to make it compatible with Linux.
The project is primarily designed to build the binder runtime libraries for embedded devices.
It also provides the `aidl` compiler for the architecture team to generate interface code offline.
The default binder libraries generated are 64-bit, but this can be overridden using CMake variables.

**For comprehensive build documentation, see [BUILD.md](BUILD.md).**

---

## Revision History

 |Date        |Component       |Version                       |Description                                             |
 |------------|----------------|------------------------------|--------------------------------------------------------|
 |22/11/2023  |AOSP            |android-13.0.0_r74            |AOSP tag android-13.0.0_r74 checkout out from Google    |
 |22/11/2023  |Binder          |android-13.0.0_r74+1.0.0      |Initial version of linux binder                         |

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Build Steps](#build-steps)
  - [Build Binder Framework](#build-binder-framework)
  - [Build Binder Example](#build-binder-example)
  - [Build AIDL generator tool](#build-aidl-generator-tool)
    - [AIDL Generator Tool Usage](#aidl-generator-tool-usage)
- [Build Options](#build-options)
  - [Quick Build Commands](#quick-build-commands)
  - [CMake Build Variables](#cmake-build-variables)
  - [Clean Builds](#clean-builds)
- [Output](#output)
- [Testing](#testing)
  - [Using Vagrant Box](#using-vagrant-box)
  - [Using KVM](#using-kvm)

---

## Prerequisites

- Ubuntu 22.04 LTS machine
- Linux Kernel 5.16.x with binder enabled (Tested with 5.16.20)
- CMake 3.22.1 or later
- GCC 11.2.0 or later (minimum GCC 9.4.0)

**For detailed kernel configuration, runtime setup, and Yocto/BitBake integration, see [BUILD.md](BUILD.md).**

---

## Build Steps

Following are the build steps to build the binder framework, binder examples and aidl generator tool.


## Build Binder Framework

### Run below command to generate binder libs, header files and servicemanager.

```bash
./build-linux-binder-aidl.sh
```

This also builds the host AIDL generator tool by default so the target build can generate
stubs/proxies. Use `no-host-aidl` if you already have `out/host/bin/aidl` available.

**Note:** For native builds (standard Linux with build-essential), just run the script without setting any environment variables. CMake will auto-detect your system GCC compiler. For cross-compilation (Yocto/embedded), set CC/CXX/CFLAGS/CXXFLAGS/LDFLAGS before running the script.

#### Following are the generated files as part of the binder framework (in `out/target/`):-

```bash
out/target/
├── bin/
│   └── servicemanager
├── include/
│   └── *.h
└── lib/
    ├── libbase.so
    ├── libbinder.so
    ├── libcutils.so
    ├── libcutils_sockets.so
    ├── liblog.so
    └── libutils.so
```

## Build Binder Example

Following are the build steps to build the binder examples. This builds the binder framework first and the binder examples.

### Run below command to build binder example

```bash
./build-binder-example.sh
```

#### Following are the libraries and binaries generated as part of binder example (in `out/target/`) :-

```bash
out/target/
├── bin/
│   ├── FWManagerService
│   └── FWManagerClient
└── lib/
    └── libfwmanager.so
```

## Build AIDL generator tool

**Note:** The AIDL compiler is primarily used by the architecture team for offline interface code generation. Production Yocto/BitBake builds do NOT require building or installing the AIDL compiler (they use pre-generated sources).

### Run below command to build aidl generator tool

```bash
./build-aidl-generator-tool.sh
```

### Following are the generated files (in `out/host/`):

```bash
out/host/
├── bin/
│   ├── aidl
│   └── aidl-cpp
└── tarball/
    └── aidl-gen-tool-android-13.0.0_r74+1.0.0.tar.bz2
```

Note: The AIDL generator tool is built and tested only on x86 machines. The tarball version can be updated using `${AIDL_GENERATOR_TARBALL}`.

The Google prebuilt AIDL generator tool for host machine is available at: <https://android.googlesource.com/platform/prebuilts/build-tools>


### AIDL Generator Tool Usage

An example to generate the `stubs and proxies` from an `.aidl` file using `aidl` generator tool

```bash
aidl --lang=cpp -I${WORKDIR} "${WORKDIR}/${SRC_DIR}" --header_out ${GEN_DIR}/${AIDL_NAME}/include -o ${GEN_DIR}/${AIDL_NAME}

#FWManager Example:

aidl --lang=cpp -I. com/test/IFirmwareUpdateStateListener.aidl --header_out gen/FWManager/include -o gen/FWManager
aidl --lang=cpp -I. com/test/FirmwareStatus.aidl --header_out gen/FWManager/include -o gen/FWManager
aidl --lang=cpp -I. com/test/IFWManager.aidl --header_out gen/FWManager/include -o gen/FWManager

#The stubs and proxies are generated in gen/FWManager and gen/FWManager/include
```

---

## Build Options

The build system uses CMake and provides wrapper scripts for convenience during development.

## Quick Build Commands

All wrapper scripts support `--help` and `--clean` options:

```bash
# Build target SDK (libraries + servicemanager)
# Also builds host AIDL tools unless --no-host-aidl is used
./build-linux-binder-aidl.sh [--clean] [--no-host-aidl]

# Build examples (includes SDK build)
./build-binder-example.sh [--clean] [--clean-aidl]

# Build AIDL compiler (architecture team only)
./build-aidl-generator-tool.sh [--clean]
```

**For production Yocto/BitBake integration, see [BUILD.md](BUILD.md).**

## CMake Build Variables

**For production Yocto/BitBake usage and detailed CMake documentation, see [BUILD.md](BUILD.md).**

Development wrapper scripts (`build-*.sh`) automatically handle CMake variables. For manual CMake usage:

| Variable | Description | Default |
|----------|-------------|---------|
| `BUILD_HOST_AIDL` | Build AIDL compiler (architecture team only) | `ON` |
| `TARGET_LIB64_VERSION` | Build 64-bit libraries | Auto-detect |
| `TARGET_LIB32_VERSION` | Build 32-bit libraries | `OFF` |

**See [BUILD.md](BUILD.md) for:**

- Complete CMake variable reference
- Production build configuration
- Cross-compilation setup
- Yocto/BitBake recipe examples

## Clean Builds

All wrapper scripts support the `--clean` flag:

```bash
# Clean and rebuild SDK
./build-linux-binder-aidl.sh --clean

# Clean and rebuild examples (with optional AIDL regeneration)
./build-binder-example.sh --clean --clean-aidl

# Clean and rebuild AIDL compiler
./build-aidl-generator-tool.sh --clean
```

Manual cleanup:

```bash
# Clean target build only
rm -rf out/target/ build-target/

# Clean host AIDL build only
rm -rf out/host/ build-host/

# Clean everything
rm -rf out/ build-target/ build-host/
```

---

## Output

The default generated binder libs are 64-bit. This can be modified using `TARGET_LIB64_VERSION` or `TARGET_LIB32_VERSION` CMake variables.

**Target SDK** (libraries for embedded devices) are installed to `out/target/`:

```bash
out/target/
    ├── bin/
    │   ├── servicemanager
    │   ├── FWManagerService
    │   ├── FWManagerClient
    │   └── binder-device
    ├── include/
    │   └── *.h
    └── lib/
        ├── libbinder.so
        ├── libcutils.so
        ├── libcutils_sockets.so
        ├── libutils.so
        ├── liblog.so
        └── libfwmanager.so
```

**Host AIDL Compiler** (architecture team only) is installed to `out/host/`:

```bash
out/host/
    └── bin/
        ├── aidl
        └── aidl-cpp
```

Refer to [OUTPUT.md](OUTPUT.md) for a complete list of installed files.

---

# Testing
This project includes comprehensive test suites to validate the build process and ensure quality for releases.

### Quick Validation Test

For fast validation during development:

```bash
./quick_test.sh
```

This runs a streamlined test that:
1. Clones Android sources (if not present)
2. Validates all build scripts
3. Tests clean operations
4. Builds host AIDL tools
5. Builds target binder libraries
6. Builds target libraries via direct CMake (per BUILD.md examples)
7. Verifies all outputs

**Time:** ~5-10 minutes (faster on subsequent runs with cached builds)

### Comprehensive Build Test

For thorough validation before releases:

```bash
./test_build.sh
```

This comprehensive test suite validates:
- Android source repository cloning
- All 8 required AOSP repositories
- Patch application
- Build script functionality
- Clean operations
- Help flags
- Host AIDL compiler build
- Target binder libraries build
- Incremental builds
- Zero warnings/errors policy
- Output file verification

**Time:** ~10-20 minutes

### CI/CD Integration

A GitHub Actions workflow is provided in `.github/workflows/build-test.yml` that:
- Runs on every push and pull request
- Executes both quick and comprehensive tests
- Uploads build artifacts
- Validates release readiness for tagged commits

### Release Validation Checklist

Before creating a release:

1. ✅ Run `./test_build.sh` successfully
2. ✅ Verify zero build warnings/errors
3. ✅ Test on clean Ubuntu 22.04 LTS system
4. ✅ Update CHANGELOG.md with changes
5. ✅ Tag release with version (e.g., `v1.0.1`)
6. ✅ Verify CI/CD pipeline passes

---

## Runtime Testing
## Using Vagrant Box

Refer : https://www.vagrantup.com/

### 1. Download and use the android binder enabled Vagrant box

#### Download Vagrant Box from Vagrant Cloud

- Use [__rahulraas/ubuntu-binder-22.04__](https://app.vagrantup.com/rahulraas/boxes/ubuntu-binder-22.04) directly from Vagrant cloud (https://app.vagrantup.com/boxes/search)
- __Vagrantfile__

```bash
Vagrant.configure("2") do |config|
  config.vm.box = "rahulraas/ubuntu-binder-22.04"
  config.vm.box_version = "1.0.0"
end
```

###  OR

#### Download Vagrant Box from Pre Shared Location

* Download __ubuntu-binder-22.04.box__ from a shared location
* Add the __ubuntu-binder-22.04__ box to Vagrant

```bash
vagrant box add ubuntu-binder-22.04 ubuntu-binder-22.04.box
```

- Create the Vagrant Environment with binder Vagrant box

```bash
vagrant init ubuntu-binder-22.04

# OR

#Create a Vagrantfile with binder Vagrant box
#--------------------------------------------------
config.vm.box = "ubuntu-binder-22.04"

# Set the machine name (optional)
config.vm.define "ubuntu-binder-22.04"
#--------------------------------------------------
```

#### 2. Launch and Access the Virtual Machine

```bash
vagrant up
vagrant ssh
```

#### 3. Build the binder libs and example bins

```bash
sudo bash (need to be a super user to access /dev/binder)
./build-binder-example.sh
```
<a name="3-build-the-binder-libs-and-example-bins"></a>

#### 4. Move to the bin directory and update the LD_LIBRARY_PATH with binder libs

```bash
cd out/target/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$(pwd)/../lib
```

#### 5. Run the servicemanager

```bash
./servicemanager &
```

#### 6. Run example service

```bash
./FWManagerService &
```

#### 7. Run example client

```bash
./FWManagerClient
```
<a name="7.-run-example-client"></a>

## Using KVM

### 1. Create an Ubuntu 22.04 LTS KVM with Kernel 5.16.20

- Refer : https://ubuntu.com/download/kvm#:~:text=Install%20KVM&text=This%20is%20the%20best%20outcome,hardware%20acceleration%20in%20your%20CPU.

### 2. Create binder device node if not exists

```bash
./binder-device /dev/binderfs/binder-control /dev/binderfs/binder
chmod 0755 /dev/binderfs/binder
ln -sf /dev/binderfs/binder /dev/binder
```

### 3. Build the binder libs and run the servicemanager and example server and client.

Run [Step 3](#3-build-the-binder-libs-and-example-bins) to [Step 7](#7-run-example-client) in the [Vagrant Box](#using-vagrant-box) section.
