#/**
# * Copyright 2024 Comcast Cable Communications Management, LLC
# *
# * Licensed under the Apache License, Version 2.0 (the "License");
# * you may not use this file except in compliance with the License.
# * You may obtain a copy of the License at
# *
# * http://www.apache.org/licenses/LICENSE-2.0
# *
# * Unless required by applicable law or agreed to in writing, software
# * distributed under the License is distributed on an "AS IS" BASIS,
# * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# * See the License for the specific language governing permissions and
# * limitations under the License.
# *
# * SPDX-License-Identifier: Apache-2.0
# */

# ** @brief : Build binder idl module
# *
# * The cmake is used to build the libbinder and its dependent libraries.
# * Also, builds aidl, aidl-cpp, and binder-device binaries based on build flags.
# * For more information refer README file.
# *
# * Design note:
# *
# *  - One thin "Core SDK" (Android libs + servicemanager) is built once.
# *  - The AIDL compiler (aidl / aidl-cpp) is a host tool layered on top of
# *    that Core SDK and reuses those libs instead of rebuilding them.
# *  - In the future we may optionally build a *target* AIDL binary too
# *    (BUILD_TARGET_AIDL) but this is documented and currently disabled
# *    by default to avoid duplication.
# */

cmake_minimum_required (VERSION 3.8)

set(PACKAGE_NAME          "linux-binder-idl")
set(PACKAGE_VERSION       "2.0.0")
set(ANDROID_VERSION       "android-13.0.0_r74")
set(PACKAGE_STRING        "${PACKAGE_NAME} ${PACKAGE_VERSION}")

project(${PACKAGE_NAME} LANGUAGES C CXX)

# Set C++ standard globally to avoid warnings about passing to C compiler
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Default to Release for single-config generators unless explicitly set.
if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()


###########################################################
# Set all the path variables (must be before any checks)
###########################################################
set(LINUX_BINDER_AIDL_ROOT "${CMAKE_CURRENT_LIST_DIR}")
set(LINUX_BINDER_AIDL_ROOT_OUT "${CMAKE_CURRENT_LIST_DIR}/out")
if(NOT EXISTS ${LINUX_BINDER_AIDL_ROOT_OUT})
    file(MAKE_DIRECTORY ${LINUX_BINDER_AIDL_ROOT_OUT})
endif()

set(ANDROID_DIR "${CMAKE_CURRENT_LIST_DIR}/android")

set(ANDROID_LOGGING_DIR ${ANDROID_DIR}/logging)
set(ANDROID_BASE_DIR ${ANDROID_DIR}/libbase)
set(ANDROID_CORE_DIR ${ANDROID_DIR}/core)
set(ANDROID_NATIVE_DIR ${ANDROID_DIR}/native)
set(ANDROID_FMTLIB_DIR ${ANDROID_DIR}/fmtlib)
set(ANDROID_AIDL_TOOL_DIR ${ANDROID_DIR}/aidl)
set(ANDROID_BUILD_TOOLS_DIR ${ANDROID_DIR}/build-tools/linux-x86)

###########################################################
# Stage android kernel headers (linux/, asm/, asm-generic/)
# so <linux/android/binder.h> resolves to the project's copy
# instead of the host system's /usr/include version.
# Only kernel UAPI headers are staged — NOT musl C library
# headers — to avoid conflicts with the host's glibc.
###########################################################
set(ANDROID_KERNEL_HEADERS_DIR "${CMAKE_BINARY_DIR}/android-kernel-headers")
if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "x86_64|amd64")
    set(_SYSROOT_ARCH "x86_64-linux-musl")
else()
    set(_SYSROOT_ARCH "i686-linux-musl")
endif()
set(_SYSROOT_INCLUDE "${ANDROID_DIR}/build-tools/sysroots/${_SYSROOT_ARCH}/include")

if(EXISTS "${_SYSROOT_INCLUDE}/linux" AND NOT EXISTS "${ANDROID_KERNEL_HEADERS_DIR}/linux")
    file(MAKE_DIRECTORY "${ANDROID_KERNEL_HEADERS_DIR}")
    file(CREATE_LINK "${_SYSROOT_INCLUDE}/linux"
         "${ANDROID_KERNEL_HEADERS_DIR}/linux" SYMBOLIC)
    file(CREATE_LINK "${_SYSROOT_INCLUDE}/asm"
         "${ANDROID_KERNEL_HEADERS_DIR}/asm" SYMBOLIC)
    file(CREATE_LINK "${_SYSROOT_INCLUDE}/asm-generic"
         "${ANDROID_KERNEL_HEADERS_DIR}/asm-generic" SYMBOLIC)
endif()

# Prioritize project kernel headers over system /usr/include/linux/
include_directories(BEFORE SYSTEM "${ANDROID_KERNEL_HEADERS_DIR}")

###########################################################
find_package(PkgConfig)

###########################################################
# High-level build switches
###########################################################
# Build the Core SDK: Android libraries + servicemanager
# Always enabled because the AIDL compiler depends on these libraries.

# Build the host AIDL compiler (x86_64 or native host)
# This is the "aidl compiler / aidl generator" host tool.
option(BUILD_HOST_AIDL "Build host AIDL compiler (aidl / aidl-cpp)" ON)

# Future option (Option 4): build a target AIDL compiler as well.
# The idea is: same sources, but built for a target architecture and
# installed under a target tools directory. For now, we keep this
# option present but unused, to document the intended behaviour.
#
# option(BUILD_TARGET_AIDL "Also build a target AIDL compiler (future/optional)" OFF)

###########################################################
# Set build environment flags
###########################################################
if (NOT DEFINED CMAKE_C_COMPILER)
    message("Set GCC Compiler")
    set(CMAKE_C_COMPILER gcc)
endif ()

if (NOT DEFINED CMAKE_CXX_COMPILER)
    message("Set G++ Compiler")
    set(CMAKE_CXX_COMPILER g++)
endif ()

if (NOT DEFINED CMAKE_POSITION_INDEPENDENT_CODE)
    message("Set PIC Option")
    set(CMAKE_POSITION_INDEPENDENT_CODE TRUE)
endif ()

###########################################################
# Suppress warnings for third-party Android AOSP code
###########################################################
# This is unmodified third-party Android code - suppress all noise warnings
add_compile_options(
    -Wno-unknown-pragmas           # Ignore #pragma clang directives
    -Wno-attributes                # Ignore clang-specific attributes ([[clang::*]])
    -Wno-missing-field-initializers # Partial struct initialization is intentional
    -Wno-unused-parameter          # AOSP code has many unused params
    -Wno-unused-result             # Some Android APIs marked warn_unused_result
    -Wno-implicit-fallthrough      # Intentional switch case fallthrough
    -Wno-ignored-attributes        # Template attributes not supported on older GCC
    -Wno-type-limits               # Unsigned >= 0 checks for defensive programming
    -Wno-sign-compare              # Signed/unsigned comparison in loops
    -Wno-int-to-pointer-cast       # Legacy pointer/integer casts in binder
    -Wno-maybe-uninitialized       # False positives in conditional guards
    -Wno-comment                   # Multi-line comments with backslashes
    -Wno-bool-compare              # Boolean comparisons with constants
    -Wno-uninitialized             # 'out' variable initialization warnings
    -Wno-return-type               # Missing return statements in switch/if chains
    -w                             # Suppress ALL warnings (AOSP third-party code)
    -fno-strict-aliasing           # Disable strict aliasing (required for AOSP wire formats)
    -U_FORTIFY_SOURCE              # Disable bionic FORTIFY (uses Clang __overloadable)
    -D__ANDROID_API__=30           # Set Android API level for bionic features
)

# C++ specific warnings
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-class-memaccess -Wno-invalid-offsetof -Wno-cast-function-type -Wno-zero-as-null-pointer-constant -Wno-changes-meaning")

# Detect build environment: default to HOST unless Yocto detected or explicitly set
set(BUILD_ENV_YOCTO OFF)
set(BUILD_ENV_HOST ON)

# Check for Yocto environment indicators
if (DEFINED ENV{OECORE_NATIVE_SYSROOT} OR DEFINED ENV{OECORE_TARGET_SYSROOT} OR BUILD_ENV_YOCTO)
    message("Yocto environment detected or explicitly set")
    set(BUILD_ENV_YOCTO ON)
    set(BUILD_ENV_HOST OFF)
    message("Set build environment as Yocto")
else ()
    message("Set build environment as host (native)")
endif ()

# Generate shared libs as default
set(BUILD_SHARED_LIB ON)
if (BUILD_STATIC_LIB)
    message("Generating static libs")
    set(BUILD_SHARED_LIB OFF)
else ()
    message("Generate shared libs")
endif ()

# Set build with liblog flag
set(BUILD_WITH_LIBLOG ON)
if (BUILD_WITHOUT_LIBLOG)
    message("Setting BUILD_WITHOUT_LIBLOG flag to build liblog seperately")
    set(BUILD_WITH_LIBLOG OFF)
endif ()

# Set default binder library as 32 bit (ARM userspace target)
# Use conditional set so -DTARGET_LIB32_VERSION=OFF can override for future 64-bit
if (NOT DEFINED TARGET_LIB32_VERSION)
    set(TARGET_LIB32_VERSION ON)
endif()
if (TARGET_LIB64_VERSION)
    message("Building 64bit binder library")
    set(TARGET_LIB32_VERSION OFF)
endif ()

# Binder wire protocol vs compile bitness (linux_binder_idl#42).
# The binder protocol version is a DIFFERENT axis from the ELF compile bitness:
#   - protocol 7 (BINDER_IPC_32BIT=1, 32-bit binder handles) — legacy, for an
#     all-32-bit userspace on a CONFIG_ANDROID_BINDER_IPC_32BIT kernel.
#   - protocol 8 (unset, 64-bit handles) — required for a MIXED platform (32-bit
#     MW + 64-bit vendor sharing one kernel); a 32-bit process CAN run protocol 8.
# Default: follow the compile bitness (32-bit -> protocol 7) for backward
# compatibility. Override with -DBINDER_IPC_32BIT=OFF to build a 32-bit
# protocol-8 library (the mixed config), or =ON to force protocol 7.
if (NOT DEFINED BINDER_IPC_32BIT)
    if (TARGET_LIB32_VERSION)
        set(BINDER_IPC_32BIT ON)
    else ()
        set(BINDER_IPC_32BIT OFF)
    endif ()
endif ()
if (BINDER_IPC_32BIT AND NOT TARGET_LIB32_VERSION)
    message(FATAL_ERROR
        "BINDER_IPC_32BIT=ON (protocol 7) requires a 32-bit build; a 64-bit binder "
        "library must use protocol 8 — set -DBINDER_IPC_32BIT=OFF for 64-bit.")
endif ()

###########################################################
# Set all the path variables
###########################################################
set(LINUX_BINDER_AIDL_ROOT "${CMAKE_CURRENT_LIST_DIR}")
set(LINUX_BINDER_AIDL_ROOT_OUT "${CMAKE_CURRENT_LIST_DIR}/out")
if(NOT EXISTS ${LINUX_BINDER_AIDL_ROOT_OUT})
    file(MAKE_DIRECTORY ${LINUX_BINDER_AIDL_ROOT_OUT})
endif()

set(ANDROID_DIR "${CMAKE_CURRENT_LIST_DIR}/android")

set(ANDROID_LOGGING_DIR ${ANDROID_DIR}/logging)
set(ANDROID_BASE_DIR ${ANDROID_DIR}/libbase)
set(ANDROID_CORE_DIR ${ANDROID_DIR}/core)
set(ANDROID_NATIVE_DIR ${ANDROID_DIR}/native)
set(ANDROID_FMTLIB_DIR ${ANDROID_DIR}/fmtlib)
set(ANDROID_AIDL_TOOL_DIR ${ANDROID_DIR}/aidl)
set(ANDROID_BUILD_TOOLS_DIR ${ANDROID_DIR}/build-tools/linux-x86)

set(BINDER_DIR ${ANDROID_NATIVE_DIR}/libs/binder)
set(LIBUTILS_DIR ${ANDROID_CORE_DIR}/libutils)
set(LIBCUTILS_DIR ${ANDROID_CORE_DIR}/libcutils)
set(LIBBASE_DIR ${ANDROID_BASE_DIR})
set(LIBLOG_DIR ${ANDROID_LOGGING_DIR}/liblog)
set(LIBSYSTEM_DIR ${ANDROID_CORE_DIR}/libsystem)
set(LIBFMT_DIR ${ANDROID_FMTLIB_DIR})
set(LIBPROCESSGROUP_DIR ${ANDROID_CORE_DIR}/libprocessgroup)
set(LIBGTEST_DIR ${ANDROID_DIR}/googletest/googletest)
set(AIDL_DIR ${ANDROID_AIDL_TOOL_DIR})

set(SERVICEMANAGER_DIR ${ANDROID_NATIVE_DIR}/cmds/servicemanager)

set(BINDER_AIDL_GEN_DIR "${CMAKE_CURRENT_LIST_DIR}/binder_aidl_gen")

set(BINDER_TEST_DIR "${CMAKE_CURRENT_LIST_DIR}/test")
set(FWMANAGER_TEST_DIR ${BINDER_TEST_DIR}/FWManagerService)

set(TOOLS_DIR "${CMAKE_CURRENT_LIST_DIR}/tools")
#set(TOOLS_X86_BIN_DIR ${TOOLS_DIR}/linux-x86/bin)

set(GENERATED_DIR ${CMAKE_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GENERATED_DIR})

if (NOT DEFINED CMAKE_INSTALL_LIBDIR)
    message("Set cmake install lib directory")
    set(CMAKE_INSTALL_LIBDIR ${CMAKE_INSTALL_PREFIX}/lib)
    message("cmake install lib dir ${CMAKE_INSTALL_LIBDIR}")
endif ()

if (NOT DEFINED CMAKE_INSTALL_BINDIR)
    message("Set cmake install bin directory")
    set(CMAKE_INSTALL_BINDIR ${CMAKE_INSTALL_PREFIX}/bin)
    message("cmake install bin dir ${CMAKE_INSTALL_BINDIR}")
endif ()

if (NOT DEFINED CMAKE_INSTALL_INCDIR)
    message("Set cmake install include directory")
    set(CMAKE_INSTALL_INCDIR ${CMAKE_INSTALL_PREFIX}/include)
    message("cmake install header dir ${CMAKE_INSTALL_INCDIR}")
endif ()

###########################################################
# Checkout Required repos from AOSP
###########################################################
if (NOT EXISTS ${ANDROID_DIR})
    execute_process(
        COMMAND sh -c "${CMAKE_CURRENT_LIST_DIR}/clone-android-binder-repo.sh"
    )
endif()

###########################################################
# Macro to generate stubs and proxies from .aidl
###########################################################
# Determine which aidl binary to use
if (BUILD_HOST_AIDL)
    # Use aidl from current build tree
    set(AIDL_EXECUTABLE "${CMAKE_BINARY_DIR}/aidl")
else()
    # Use aidl from host output directory (must be built first)
    set(AIDL_EXECUTABLE "${LINUX_BINDER_AIDL_ROOT}/out/host/bin/aidl")
endif()

macro(AidlGenerator aidlName baseDir sources)
    set(${aidlName}_OUTPUTS "")
    foreach(src IN ITEMS ${sources})
        string(REGEX REPLACE "[.]aidl$" ".cpp" outputFilename ${src})
        set(output "${GENERATED_DIR}/${aidlName}/${outputFilename}")
        add_custom_command(
            OUTPUT  ${output}
            COMMAND ${AIDL_EXECUTABLE} --lang=cpp -I${baseDir} "${baseDir}/${src}" --header_out ${GENERATED_DIR}/${aidlName}/include -o ${GENERATED_DIR}/${aidlName}
            DEPENDS ${baseDir}/${src}
            COMMENT "[AIDL] ${src} -> ${output}"
            VERBATIM
        )
        list(APPEND ${aidlName}_OUTPUTS ${output})
    endforeach(src)
endmacro()

###########################################################
# Core SDK: Android libs + servicemanager
#
# This is the one thin SDK that both:
#   - the *target* uses (via libraries + servicemanager)
#   - the *host* AIDL compiler links against.
###########################################################

    if (BUILD_WITH_LIBLOG)
        ###########################################################
        # Android liblog
        ###########################################################

        project(log)

        set(LIBLOG_SRCS
            ${LIBLOG_DIR}/log_event_list.cpp
            ${LIBLOG_DIR}/log_event_write.cpp
            ${LIBLOG_DIR}/logger_name.cpp
            ${LIBLOG_DIR}/logger_read.cpp
            ${LIBLOG_DIR}/logger_write.cpp
            ${LIBLOG_DIR}/logprint.cpp
            ${LIBLOG_DIR}/properties.cpp
        )

        if (BUILD_SHARED_LIB)
            add_library(log SHARED ${LIBLOG_SRCS})
        else ()
            add_library(log STATIC ${LIBLOG_SRCS})
        endif ()

        target_compile_options(log PRIVATE
            -Wall -Wextra -D__linux__ -DLIBLOG_LOG_TAG=1006 -DSNET_EVENT_LOG_TAG=1397638484 -DANDROID_DEBUGGABLE=0
        )

        target_include_directories(log PRIVATE
            ${LIBLOG_DIR}/include
        )

        if (NOT BUILD_ENV_YOCTO)
            if (BUILD_SHARED_LIB)
                install(TARGETS
                    log
                    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
                )
            endif ()

            set(HEADER_FILES_DIR
                ${LIBLOG_DIR}/include/android
                ${LIBLOG_DIR}/include/log
            )

            install(
                DIRECTORY ${HEADER_FILES_DIR}
                DESTINATION ${CMAKE_INSTALL_INCDIR}
                FILES_MATCHING PATTERN "*.h"
            )
        endif ()
    endif ()

    ###########################################################
    # Android libbase
    ###########################################################

    project(base)

    set(LIBBASE_SRCS
        ${LIBBASE_DIR}/abi_compatibility.cpp
        ${LIBBASE_DIR}/chrono_utils.cpp
        ${LIBBASE_DIR}/cmsg.cpp
        ${LIBBASE_DIR}/file.cpp
        ${LIBBASE_DIR}/hex.cpp
        ${LIBBASE_DIR}/logging.cpp
        ${LIBBASE_DIR}/mapped_file.cpp
        ${LIBBASE_DIR}/parsebool.cpp
        ${LIBBASE_DIR}/parsenetaddress.cpp
        ${LIBBASE_DIR}/posix_strerror_r.cpp
        ${LIBBASE_DIR}/process.cpp
        ${LIBBASE_DIR}/properties.cpp
        ${LIBBASE_DIR}/stringprintf.cpp
        ${LIBBASE_DIR}/strings.cpp
        ${LIBBASE_DIR}/threads.cpp
        ${LIBBASE_DIR}/test_utils.cpp
        ${LIBBASE_DIR}/errors_unix.cpp
    )

    if (BUILD_SHARED_LIB)
        add_library(base SHARED ${LIBBASE_SRCS})
    else ()
        add_library(base STATIC ${LIBBASE_SRCS})
    endif ()

    target_compile_options(base PRIVATE
        -Wall -Wextra -D__linux__ -D_XOPEN_SOURCE=600 -D_FILE_OFFSET_BITS=64
    )

    target_include_directories(base PRIVATE
        ${LIBBASE_DIR}/include
        ${LIBLOG_DIR}/include
        ${LIBFMT_DIR}/include
    )

    target_link_libraries(base PRIVATE log)

    if (NOT BUILD_ENV_YOCTO)
        if (BUILD_SHARED_LIB)
            install(TARGETS
                base
                LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
            )
        endif ()

        set(HEADER_FILES_DIR ${LIBBASE_DIR}/include/android-base)

        install(
            DIRECTORY ${HEADER_FILES_DIR}
            DESTINATION ${CMAKE_INSTALL_INCDIR}
            FILES_MATCHING PATTERN "*.h"
        )
    endif()

    ###########################################################
    # Android libcutils_sockets
    ###########################################################

    project(cutils_sockets)

    set(LIBCUTILS_SOCKETS_SRCS
        ${LIBCUTILS_DIR}/sockets.cpp
        ${LIBCUTILS_DIR}/socket_inaddr_any_server_unix.cpp
        ${LIBCUTILS_DIR}/socket_local_client_unix.cpp
        ${LIBCUTILS_DIR}/socket_local_server_unix.cpp
        ${LIBCUTILS_DIR}/socket_network_client_unix.cpp
        ${LIBCUTILS_DIR}/sockets_unix.cpp
    )

    if (BUILD_SHARED_LIB)
        add_library(cutils_sockets SHARED ${LIBCUTILS_SOCKETS_SRCS})
    else ()
        add_library(cutils_sockets STATIC ${LIBCUTILS_SOCKETS_SRCS})
    endif ()

    target_include_directories(cutils_sockets PRIVATE
        ${LIBCUTILS_DIR}/include
    )

    target_compile_options(cutils_sockets PRIVATE
        -Wall -Wextra -D__linux__
    )

    target_link_libraries(cutils_sockets PRIVATE log)

    ###########################################################
    # Android libcutils
    ###########################################################

    project(cutils)

    set(LIBCUTILS_SRCS
        ${LIBCUTILS_DIR}/socket_inaddr_any_server_unix.cpp
        ${LIBCUTILS_DIR}/socket_local_client_unix.cpp
        ${LIBCUTILS_DIR}/socket_local_server_unix.cpp
        ${LIBCUTILS_DIR}/socket_network_client_unix.cpp
        ${LIBCUTILS_DIR}/sockets_unix.cpp
        ${LIBCUTILS_DIR}/ashmem-host.cpp
        ${LIBCUTILS_DIR}/fs_config.cpp
        ${LIBCUTILS_DIR}/trace-host.cpp
        ${LIBCUTILS_DIR}/config_utils.cpp
        ${LIBCUTILS_DIR}/canned_fs_config.cpp
        ${LIBCUTILS_DIR}/iosched_policy.cpp
        ${LIBCUTILS_DIR}/load_file.cpp
        ${LIBCUTILS_DIR}/native_handle.cpp
        ${LIBCUTILS_DIR}/properties.cpp
        ${LIBCUTILS_DIR}/record_stream.cpp
        ${LIBCUTILS_DIR}/strlcpy.c
        ${LIBCUTILS_DIR}/threads.cpp
        ${LIBCUTILS_DIR}/fs.cpp
        ${LIBCUTILS_DIR}/hashmap.cpp
        ${LIBCUTILS_DIR}/multiuser.cpp
        ${LIBCUTILS_DIR}/str_parms.cpp
    )

    if (BUILD_SHARED_LIB)
        add_library(cutils SHARED ${LIBCUTILS_SRCS})
    else ()
        add_library(cutils STATIC ${LIBCUTILS_SRCS})
    endif ()

    target_compile_options(cutils PRIVATE
        -Wall -Wextra -D__linux__ -Wno-psabi
    )

    target_include_directories(cutils PRIVATE
        ${LIBCUTILS_DIR}/include
        ${LIBLOG_DIR}/include
        ${LIBBASE_DIR}/include
        ${LIBPROCESSGROUP_DIR}/include
    )

    target_link_libraries(cutils PRIVATE log base cutils_sockets dl)

    if (NOT BUILD_ENV_YOCTO)
        if (BUILD_SHARED_LIB)
            install(TARGETS
                cutils_sockets
                cutils
                LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
            )
        endif()

        set(HEADER_FILES_DIR
            ${LIBCUTILS_DIR}/include/cutils
        )

        install(
            DIRECTORY ${HEADER_FILES_DIR}
            DESTINATION ${CMAKE_INSTALL_INCDIR}
            FILES_MATCHING PATTERN "*.h"
        )
    endif()

    ###########################################################
    # Android libutils
    ###########################################################

    project(utils)

    set(LIBUTILS_SRCS
        ${LIBUTILS_DIR}/Errors.cpp
        ${LIBUTILS_DIR}/FileMap.cpp
        ${LIBUTILS_DIR}/JenkinsHash.cpp
        ${LIBUTILS_DIR}/LightRefBase.cpp
        ${LIBUTILS_DIR}/NativeHandle.cpp
        ${LIBUTILS_DIR}/Printer.cpp
        ${LIBUTILS_DIR}/RefBase.cpp
        ${LIBUTILS_DIR}/SharedBuffer.cpp
        ${LIBUTILS_DIR}/StopWatch.cpp
        ${LIBUTILS_DIR}/String8.cpp
        ${LIBUTILS_DIR}/String16.cpp
        ${LIBUTILS_DIR}/StrongPointer.cpp
        ${LIBUTILS_DIR}/SystemClock.cpp
        ${LIBUTILS_DIR}/Threads.cpp
        ${LIBUTILS_DIR}/Timers.cpp
        ${LIBUTILS_DIR}/Tokenizer.cpp
        ${LIBUTILS_DIR}/Unicode.cpp
        ${LIBUTILS_DIR}/VectorImpl.cpp
        ${LIBUTILS_DIR}/misc.cpp
        ${LIBUTILS_DIR}/Looper.cpp
    )

    if (BUILD_SHARED_LIB)
        add_library(utils SHARED ${LIBUTILS_SRCS})
    else ()
        add_library(utils STATIC ${LIBUTILS_SRCS})
    endif ()

    target_compile_options(utils PRIVATE
        -Wall -Wextra -D__linux__ -DANDROID_UTILS_REF_BASE_DISABLE_IMPLICIT_CONSTRUCTION
    )

    target_include_directories(utils PRIVATE
        ${LIBUTILS_DIR}/include
        ${LIBSYSTEM_DIR}/include
        ${LIBLOG_DIR}/include
        ${LIBBASE_DIR}/include
        ${LIBCUTILS_DIR}/include
    )

    target_link_libraries(utils PRIVATE log cutils)

    if (NOT BUILD_ENV_YOCTO)
        if (BUILD_SHARED_LIB)
            install(TARGETS
                utils
                LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
            )
        endif ()

        set(HEADER_FILES_DIR
            ${LIBUTILS_DIR}/include/utils
        )

        install(
            DIRECTORY ${HEADER_FILES_DIR}
            DESTINATION ${CMAKE_INSTALL_INCDIR}
            FILES_MATCHING PATTERN "*.h"
        )
    endif()

    ###########################################################
    # Android libbinder
    ###########################################################

    project(binder)

    set(LIBBINDER_SRCS
        ${BINDER_DIR}/Binder.cpp
        ${BINDER_DIR}/BpBinder.cpp
        ${BINDER_DIR}/BufferedTextOutput.cpp
        ${BINDER_DIR}/Debug.cpp
        ${BINDER_DIR}/FdTrigger.cpp
        ${BINDER_DIR}/IInterface.cpp
        ${BINDER_DIR}/IMemory.cpp
        ${BINDER_DIR}/IPCThreadState.cpp
        ${BINDER_DIR}/IResultReceiver.cpp
        ${BINDER_DIR}/IServiceManager.cpp
        ${BINDER_DIR}/IShellCallback.cpp
        ${BINDER_DIR}/LazyServiceRegistrar.cpp
        ${BINDER_DIR}/MemoryBase.cpp
        ${BINDER_DIR}/MemoryDealer.cpp
        ${BINDER_DIR}/MemoryHeapBase.cpp
        ${BINDER_DIR}/Parcel.cpp
        ${BINDER_DIR}/ParcelableHolder.cpp
        ${BINDER_DIR}/ParcelFileDescriptor.cpp
        ${BINDER_DIR}/PersistableBundle.cpp
        ${BINDER_DIR}/ProcessState.cpp
        ${BINDER_DIR}/RpcSession.cpp
        ${BINDER_DIR}/RpcServer.cpp
        ${BINDER_DIR}/RpcState.cpp
        ${BINDER_DIR}/RpcTransportRaw.cpp
        ${BINDER_DIR}/Static.cpp
        ${BINDER_DIR}/Stability.cpp
        ${BINDER_DIR}/Status.cpp
        ${BINDER_DIR}/TextOutput.cpp
        ${BINDER_DIR}/Utils.cpp
        ${BINDER_DIR}/ServiceManagerHost.cpp
        ${BINDER_DIR}/UtilsHost.cpp
    )

if (BUILD_ENV_YOCTO OR NOT BUILD_HOST_AIDL)
    if (BUILD_ENV_YOCTO)
        message("Yocto environment")
    else ()
        message("Host/Generic environment for Core SDK binder (production)")
    endif ()
    message("Using generated prebuilt stubs and proxies")

        set(BINDER_AIDL_SRCS
            ${BINDER_AIDL_GEN_DIR}/android/os/IServiceManager.cpp
            ${BINDER_AIDL_GEN_DIR}/android/os/IServiceCallback.cpp
            ${BINDER_AIDL_GEN_DIR}/android/os/IClientCallback.cpp
            ${BINDER_AIDL_GEN_DIR}/android/os/ServiceDebugInfo.cpp
            ${BINDER_AIDL_GEN_DIR}/android/os/ConnectionInfo.cpp
        )

        add_library(binder SHARED
            ${LIBBINDER_SRCS}
            ${BINDER_AIDL_SRCS}
        )

        target_include_directories(binder PUBLIC
            ${BINDER_AIDL_GEN_DIR}/include
        )
    else ()
        message("Host/Generic environment for Core SDK binder")
        message("Generate stubs and proxies from .aidl file using aidl utility")

        set(BINDER_AIDL_SRCS
            "android/os/IServiceManager.aidl"
            "android/os/IServiceCallback.aidl"
            "android/os/IClientCallback.aidl"
            "android/os/ServiceDebugInfo.aidl"
            "android/os/ConnectionInfo.aidl"
        )

        AidlGenerator(BINDER_AIDL "${BINDER_DIR}/aidl" "${BINDER_AIDL_SRCS}")

        add_library(binder SHARED
            ${LIBBINDER_SRCS}
            ${BINDER_AIDL_OUTPUTS}
        )

        # NOTE: This dependency only applies when building AIDL in the same CMake tree
        # BUILD_HOST_AIDL is ON in this branch, so the aidl target is available.
        if (BUILD_HOST_AIDL)
            add_dependencies(binder aidl)
        endif ()

        target_include_directories(binder PUBLIC
            ${GENERATED_DIR}/BINDER_AIDL/include
        )
    endif ()

    target_include_directories(binder PUBLIC
        ${BINDER_DIR}/include
        ${BINDER_DIR}/ndk/include_cpp
        ${LIBUTILS_DIR}/include
        ${LIBLOG_DIR}/include
        ${LIBBASE_DIR}/include
        ${LIBCUTILS_DIR}/include
        ${LIBFMT_DIR}/include
        ${LIBSYSTEM_DIR}/include
        ${LIBPROCESSGROUP_DIR}/include/
    )

    if (TARGET_LIB32_VERSION)
        message("Building 32bit binder library")
    else ()
        message("Building 64bit binder library")
    endif ()
    target_compile_options(binder PRIVATE
        -Wall -Wextra -D__linux__
        -DANDROID_BASE_UNIQUE_FD_DISABLE_IMPLICIT_CONVERSION -DANDROID_UTILS_REF_BASE_DISABLE_IMPLICIT_CONSTRUCTION
    )
    # Wire protocol is independent of compile bitness (see BINDER_IPC_32BIT above).
    if (BINDER_IPC_32BIT)
        message("  binder wire protocol: 7 (BINDER_IPC_32BIT=1)")
        target_compile_options(binder PRIVATE -DBINDER_IPC_32BIT=1)
    else ()
        message("  binder wire protocol: 8")
    endif ()

    target_link_libraries(binder PRIVATE log base cutils utils pthread)

    if (NOT BUILD_ENV_YOCTO)
        install(TARGETS
            binder
            LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        )

        set(HEADER_FILES_DIR
            ${BINDER_DIR}/include/binder
            ${BINDER_DIR}/ndk/include_cpp/android
        )

        install(
            DIRECTORY ${HEADER_FILES_DIR}
            DESTINATION ${CMAKE_INSTALL_INCDIR}
            FILES_MATCHING PATTERN "*.h"
        )
    endif()

    ###########################################################
    # Android servicemanager (part of Core SDK)
    ###########################################################
    set(SERVICEMANAGER_SRCS
        ${SERVICEMANAGER_DIR}/main.cpp
        ${SERVICEMANAGER_DIR}/Access.cpp
        ${SERVICEMANAGER_DIR}/ServiceManager.cpp
    )

    add_executable(servicemanager ${SERVICEMANAGER_SRCS})

    target_compile_options(servicemanager PRIVATE
        -Wall -Wextra -D__linux__ -DANDROID_UTILS_REF_BASE_DISABLE_IMPLICIT_CONSTRUCTION
    )

    target_include_directories(servicemanager PRIVATE
        ${BINDER_DIR}/include
        ${BINDER_DIR}/include/android
        ${BINDER_DIR}/ndk/include_cpp
        ${LIBLOG_DIR}/include
        ${LIBBASE_DIR}/include
        ${LIBCUTILS_DIR}/include
        ${LIBUTILS_DIR}/include
        ${LIBFMT_DIR}/include
        ${LIBSYSTEM_DIR}/include
        ${LIBPROCESSGROUP_DIR}/include/
    )

    if (BUILD_ENV_YOCTO)
        target_include_directories(servicemanager PRIVATE
            ${BINDER_AIDL_GEN_DIR}/include
        )
    else ()
        target_include_directories(servicemanager PRIVATE
            ${GENERATED_DIR}/BINDER_AIDL/include
        )
    endif ()

    target_link_libraries(servicemanager PRIVATE binder utils cutils base log pthread)

    if (NOT BUILD_ENV_YOCTO)
        install(
            TARGETS servicemanager
            RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        )
    endif ()


###########################################################
# Host AIDL compiler (aidl / aidl-cpp) – host tool only
#
# This is the AIDL compiler / generator. It assumes that the
# Core SDK is present in this build and
# reuses libbase, liblog, libcutils, etc instead of rebuilding.
#
# In the future, a target AIDL build (BUILD_TARGET_AIDL) would
# mirror this but use a target toolchain and install under a
# target tools directory. That is Option 4, intentionally kept
# as a documented but disabled behaviour for now.
###########################################################
# Build host AIDL compiler regardless of environment (needed for code generation)
if (BUILD_HOST_AIDL)

    project (aidl)
    message("Build host AIDL compiler (aidl / aidl-cpp)")

    #######################################################
    # Android FMT
    #######################################################
    add_library(fmt STATIC ${LIBFMT_DIR}/src/format.cc)

    target_include_directories(fmt PRIVATE
        ${LIBFMT_DIR}/include
    )

    target_compile_options(fmt PRIVATE
        "-fno-exceptions"
        "-UNDEBUG"
    )

    #######################################################
    # Android GTEST
    #######################################################
    add_library(gtest STATIC ${LIBGTEST_DIR}/src/gtest-all.cc)

    target_include_directories(gtest PRIVATE
        ${LIBGTEST_DIR}
        ${LIBGTEST_DIR}/include
    )

    target_link_libraries(gtest PRIVATE pthread)

    #######################################################
    # FLEX/BISON for AIDL language
    #######################################################
    find_package(FLEX)
    find_package(BISON)

    set(FLEX_FOUND "True")
    set(FLEX_EXECUTABLE "${ANDROID_BUILD_TOOLS_DIR}/bin/flex")

    set(FLEX_OUT "${GENERATED_DIR}/aidl_language_l.cpp")
    set(FLEX_SRC "${AIDL_DIR}/aidl_language_l.ll")

    FLEX_TARGET(lexer ${FLEX_SRC} ${FLEX_OUT})

    set(BISON_FOUND "True")
    set(BISON_EXECUTABLE "${ANDROID_BUILD_TOOLS_DIR}/bin/bison")

    set(BISON_OUT       "${GENERATED_DIR}/aidl_language_y.cpp")
    set(BISON_DEFINES   "${GENERATED_DIR}/aidl_language_y.h")
    set(BISON_SRC       "${AIDL_DIR}/aidl_language_y.yy")

    BISON_TARGET(parser ${BISON_SRC} ${BISON_OUT}
        COMPILE_FLAGS   "-d"
        DEFINES_FILE    ${BISON_DEFINES}
    )

    #######################################################
    # aidl-common static library
    #######################################################
    set(AIDL_COMMON_SRCS
        ${AIDL_DIR}/aidl_checkapi.cpp
        ${AIDL_DIR}/aidl_const_expressions.cpp
        ${AIDL_DIR}/aidl_dumpapi.cpp
        ${AIDL_DIR}/aidl_language.cpp
        ${AIDL_DIR}/aidl_to_cpp_common.cpp
        ${AIDL_DIR}/aidl_to_cpp.cpp
        ${AIDL_DIR}/aidl_to_java.cpp
        ${AIDL_DIR}/aidl_to_ndk.cpp
        ${AIDL_DIR}/aidl_to_rust.cpp
        ${AIDL_DIR}/aidl_typenames.cpp
        ${AIDL_DIR}/aidl.cpp
        ${AIDL_DIR}/ast_java.cpp
        ${AIDL_DIR}/check_valid.cpp
        ${AIDL_DIR}/code_writer.cpp
        ${AIDL_DIR}/comments.cpp
        ${AIDL_DIR}/diagnostics.cpp
        ${AIDL_DIR}/generate_aidl_mappings.cpp
        ${AIDL_DIR}/generate_cpp.cpp
        ${AIDL_DIR}/generate_java_binder.cpp
        ${AIDL_DIR}/generate_java.cpp
        ${AIDL_DIR}/generate_ndk.cpp
        ${AIDL_DIR}/generate_rust.cpp
        ${AIDL_DIR}/import_resolver.cpp
        ${AIDL_DIR}/io_delegate.cpp
        ${AIDL_DIR}/location.cpp
        ${AIDL_DIR}/logging.cpp
        ${AIDL_DIR}/options.cpp
        ${AIDL_DIR}/parser.cpp
        ${AIDL_DIR}/permission.cpp
        ${AIDL_DIR}/preprocess.cpp
    )

    add_library(aidl-common STATIC
        ${AIDL_COMMON_SRCS}
        ${FLEX_lexer_OUTPUTS}
        ${BISON_parser_OUTPUTS}
    )

    target_include_directories(aidl-common PRIVATE
        ${AIDL_DIR}
        ${LIBLOG_DIR}/include
        ${LIBBASE_DIR}/include
        ${LIBFMT_DIR}/include
        ${LIBGTEST_DIR}/include
        ${GENERATED_DIR}
    )

    target_compile_options(aidl-common PRIVATE
        -O0 -g -fpermissive -Wall -Wextra -D__linux__
    )

    target_link_libraries(aidl-common PRIVATE
        base     # from Core SDK
        cutils   # from Core SDK
        gtest
        fmt
    )

    #######################################################
    # AIDL host executables: aidl & aidl-cpp
    #######################################################
    add_executable(aidl ${AIDL_DIR}/main.cpp)

    target_include_directories(aidl PRIVATE
        ${AIDL_DIR}
        ${LIBLOG_DIR}/include
        ${LIBBASE_DIR}/include
        ${LIBFMT_DIR}/include
    )

    target_compile_options(aidl PRIVATE
        -O0 -g -fpermissive -Wall -Wextra -D__linux__
    )

    target_link_libraries(aidl PRIVATE
        aidl-common
        base
        log
    )

    add_executable(aidl-cpp ${AIDL_DIR}/main.cpp)

    target_include_directories(aidl-cpp PRIVATE
        ${AIDL_DIR}
        ${LIBLOG_DIR}/include
        ${LIBBASE_DIR}/include
        ${LIBFMT_DIR}/include
    )

    target_compile_options(aidl-cpp PRIVATE
        -O0 -g -fpermissive -Wall -Wextra -D__linux__ -DAIDL_CPP_BUILD
    )

    target_link_libraries(aidl-cpp PRIVATE
        aidl-common
        base
        log
    )

    # NOTE (Option 4 – documented behaviour):
    # A BUILD_TARGET_AIDL path would mirror all of the above, but with:
    #  - target toolchain / sysroot instead of host
    #  - output into a "target tools" bin directory
    #  - reused Core SDK *target* libs instead of rebuilding.
    # This is intentionally not wired up yet to avoid duplicate builds.

endif() # BUILD_HOST_AIDL

###########################################################
# Optional binder-device utility
###########################################################
if (BUILD_BINDER_DEVICE_UTILITY)
    add_executable(binder-device
        ${TOOLS_DIR}/BinderDevice.c
    )

    install(
        TARGETS binder-device
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    )
endif ()

# Keep existing host add-ons if any (not changed by this refactor)
# Only include if building with interfaces (not during toolchain build)
if (DEFINED INTERFACES_ROOT_DIRS AND NOT "${INTERFACES_ROOT_DIRS}" STREQUAL "")
    include(${CMAKE_CURRENT_LIST_DIR}/host/CMakeLists.inc)
endif()
