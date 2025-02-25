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

cmake_minimum_required (VERSION 3.8)

set(PACKAGE_NAME          "linux-binder-idl")
set(PACKAGE_VERSION       "1.0.0")
set(ANDROID_VERSION       "android-13.0.0_r74")
set(PACKAGE_STRING        "${PACKAGE_NAME} ${PACKAGE_VERSION}")

project(${PACKAGE_NAME} LANGUAGES C CXX)

find_package(PkgConfig)


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

# Set default build environment as yocto
set(BUILD_ENV_YOCTO ON)
if (BUILD_ENV_HOST)
    message("Set build environment as host")
    # Set build environment to Yocto
    set(BUILD_ENV_YOCTO OFF)
else ()
    message("Set build environment as Yocto")
endif ()


# Generate shared libs as default
set(BUILD_SHARED_LIB ON)
if (BUILD_STATIC_LIB)
    message("Generating static libs")
    # Generate static libs
    set(BUILD_SHARED_LIB OFF)
else ()
    message("Generate shared libs")
endif ()

# Set build with liblog flag
set(BUILD_WITH_LIBLOG ON)
if (BUILD_WITHOUT_LIBLOG)
    message("Setting BUILD_WITHOUT_LIBLOG flag to build liblog seperately")
    # Set build without liblog flag
    set(BUILD_WITH_LIBLOG OFF)
endif ()

# Set default binder library as 32 bit
set(TARGET_LIB32_VERSION ON)
if (TARGET_LIB64_VERSION)
    message("Building 64bit binder library")
    # Set default binder library as 64 bit
    set(TARGET_LIB32_VERSION OFF)
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

set(ANDOIRD_LOGGING_DIR ${ANDROID_DIR}/logging)
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
set(LIBLOG_DIR ${ANDOIRD_LOGGING_DIR}/liblog)
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

set(CMAKE_INSTALL_PREFIX ${CMAKE_CURRENT_LIST_DIR}/local)

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
macro(AidlGenerator aidlName baseDir sources)
    set(${aidlName}_OUTPUTS "")
    foreach(src IN ITEMS ${sources})
        string(REGEX REPLACE "[.]aidl$" ".cpp" outputFilename ${src})
        set(output "${GENERATED_DIR}/${aidlName}/${outputFilename}")
        add_custom_command(
            OUTPUT  ${output}
            #COMMAND ${TOOLS_X86_BIN_DIR}/aidl-cpp -I${baseDir} "${baseDir}/${src}" ${GENERATED_DIR}/${aidlName}/include ${output}
            #COMMAND ${CMAKE_BINARY_DIR}/aidl --lang=cpp --ninja -I ${base_dir} "${base_dir}/${src}" --header_out ${GENERATED_DIR}/include -o ${GENERATED_DIR}
            #COMMAND ${ANDROID_BUILD_TOOLS_DIR}/bin/aidl --lang=cpp -I${baseDir} "${baseDir}/${src}" --header_out ${GENERATED_DIR}/${aidlName}/include -o ${GENERATED_DIR}/${aidlName}
            COMMAND ${CMAKE_BINARY_DIR}/aidl --lang=cpp -I${baseDir} "${baseDir}/${src}" --header_out ${GENERATED_DIR}/${aidlName}/include -o ${GENERATED_DIR}/${aidlName}
            DEPENDS ${baseDir}/${src}
            COMMENT "[AIDL] ${src} -> ${output}"
            VERBATIM
        )
        list(APPEND ${aidlName}_OUTPUTS ${output})
    endforeach(src)
endmacro()

###########################################################
# Common include directories
###########################################################
#include_directories(
#    ${BINDER_DIR}/include
#    ${LIBUTILS_DIR}/include
#    ${LIBCUTILS_DIR}/include
#    ${LIBBASE_DIR}/include
#    ${LIBLOG_DIR}/include
#    ${LIBSYSTEM_DIR}/include
#)

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
        -Wall -Wextra -std=c++17 -D__linux__ -DLIBLOG_LOG_TAG=1006 -DSNET_EVENT_LOG_TAG=1397638484 -DANDROID_DEBUGGABLE=0
    )

    target_include_directories(log PRIVATE
        ${LIBLOG_DIR}/include
    )

    if (BUILD_SHARED_LIB)
        # Install the liblog library
        install(TARGETS
            log

            LIBRARY
            DESTINATION ${CMAKE_INSTALL_LIBDIR}
        )
    endif ()

    # Install the header files
    set(HEADER_FILES_DIR
        ${LIBLOG_DIR}/include/android
        ${LIBLOG_DIR}/include/log
    )

    install(
        DIRECTORY
        ${HEADER_FILES_DIR}

        DESTINATION ${CMAKE_INSTALL_INCDIR}
        FILES_MATCHING
        PATTERN "*.h"   # Specify the pattern to match header files
    )
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
    -Wall -Wextra -std=c++17 -D__linux__ -D_XOPEN_SOURCE=600 -D_FILE_OFFSET_BITS=64
)

target_include_directories(base PRIVATE
    ${LIBBASE_DIR}/include
    ${LIBLOG_DIR}/include
    ${LIBFMT_DIR}/include
)

target_link_libraries(base PRIVATE log)

if (BUILD_SHARED_LIB)
    # Install the libbase library
    install(TARGETS
        base

        LIBRARY
        DESTINATION ${CMAKE_INSTALL_LIBDIR}
    )
endif ()

# Install the header files
set(HEADER_FILES_DIR ${LIBBASE_DIR}/include/android-base)

install(
    DIRECTORY ${HEADER_FILES_DIR}

    DESTINATION ${CMAKE_INSTALL_INCDIR}
    FILES_MATCHING
    PATTERN "*.h"   # Specify the pattern to match header files
)

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
    -Wall -Wextra -std=c++17 -D__linux__
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
    -Wall -Wextra -std=c++17 -D__linux__ -Wno-psabi
)

target_include_directories(cutils PRIVATE
    ${LIBCUTILS_DIR}/include
    ${LIBLOG_DIR}/include
    ${LIBBASE_DIR}/include
    ${LIBPROCESSGROUP_DIR}/include
)

target_link_libraries(cutils PRIVATE log base cutils_sockets dl)

if (BUILD_SHARED_LIB)
    # Install the libcutils_sockets and libcutils library
    install(TARGETS
        cutils_sockets
        cutils

        LIBRARY
        DESTINATION ${CMAKE_INSTALL_LIBDIR}
    )
endif()

# Install the header files
set(HEADER_FILES_DIR
    ${LIBCUTILS_DIR}/include/cutils
)
#${LIBCUTILS_DIR}/include/private

install(
    DIRECTORY
    ${HEADER_FILES_DIR}

    DESTINATION ${CMAKE_INSTALL_INCDIR}
    FILES_MATCHING
    PATTERN "*.h"   # Specify the pattern to match header files
)

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
    -Wall -Wextra -std=c++17 -D__linux__ -DANDROID_UTILS_REF_BASE_DISABLE_IMPLICIT_CONSTRUCTION
)

target_include_directories(utils PRIVATE
    ${LIBUTILS_DIR}/include
    ${LIBSYSTEM_DIR}/include
    ${LIBLOG_DIR}/include
    ${LIBBASE_DIR}/include
    ${LIBCUTILS_DIR}/include
)

target_link_libraries(utils PRIVATE log cutils)

if (BUILD_SHARED_LIB)
    # Install the libutils library
    install(TARGETS
        utils

        LIBRARY
        DESTINATION ${CMAKE_INSTALL_LIBDIR}
    )
endif ()

# Install the header files
set(HEADER_FILES_DIR
    ${LIBUTILS_DIR}/include/utils
)
#${LIBUTILS_DIR}/include/system

install(
    DIRECTORY
    ${HEADER_FILES_DIR}

    DESTINATION ${CMAKE_INSTALL_INCDIR}
    FILES_MATCHING
    PATTERN "*.h"   # Specify the pattern to match header files
)

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

if (BUILD_ENV_YOCTO)
    message("Yocto environment")
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
    message("Host environment")
    message("Build aidl generator utility")
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

    add_dependencies(binder aidl)

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
    target_compile_options(binder PRIVATE
        -Wall -Wextra -std=c++17 -D__linux__ -Wextra-semi -Wzero-as-null-pointer-constant
        -DANDROID_BASE_UNIQUE_FD_DISABLE_IMPLICIT_CONVERSION -DANDROID_UTILS_REF_BASE_DISABLE_IMPLICIT_CONSTRUCTION
        -DBINDER_IPC_32BIT=1
    )
else ()
    message("Building 64bit binder library")
    target_compile_options(binder PRIVATE
        -Wall -Wextra -std=c++17 -D__linux__ -Wextra-semi -Wzero-as-null-pointer-constant
        -DANDROID_BASE_UNIQUE_FD_DISABLE_IMPLICIT_CONVERSION -DANDROID_UTILS_REF_BASE_DISABLE_IMPLICIT_CONSTRUCTION
    )
endif ()

target_link_libraries(binder PRIVATE log base cutils utils pthread)

# Install the libbinder library
install(TARGETS
    binder

    LIBRARY
    DESTINATION ${CMAKE_INSTALL_LIBDIR}
)

set(HEADER_FILES_DIR
    ${BINDER_DIR}/include/binder
    ${BINDER_DIR}/ndk/include_cpp/android
)

# Install the header files
install(
    DIRECTORY
    ${HEADER_FILES_DIR}

    DESTINATION ${CMAKE_INSTALL_INCDIR}
    FILES_MATCHING
    PATTERN "*.h"   # Specify the pattern to match header files
)

###########################################################
# Android servicemanager
###########################################################
set(SERVICEMANAGER_SRCS
    ${SERVICEMANAGER_DIR}/main.cpp
    ${SERVICEMANAGER_DIR}/Access.cpp
    ${SERVICEMANAGER_DIR}/ServiceManager.cpp
)

add_executable(servicemanager ${SERVICEMANAGER_SRCS})

target_compile_options(servicemanager PRIVATE
    -Wall -Wextra -std=c++17 -D__linux__ -DANDROID_UTILS_REF_BASE_DISABLE_IMPLICIT_CONSTRUCTION
)

#target_compile_definitions(servicemanager PRIVATE
#    -D__linux__ -DANDROID_UTILS_REF_BASE_DISABLE_IMPLICIT_CONSTRUCTION
#)

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

# Install the servicemanager binary
install(
    TARGETS
    servicemanager

    RUNTIME
    DESTINATION ${CMAKE_INSTALL_BINDIR}
)

if (BUILD_ENV_HOST)
    ###########################################################
    # Android AIDL generator
    ###########################################################

    project (aidl)
    message("Build aidl compiler")

    # Android FMT
    add_library(fmt STATIC ${LIBFMT_DIR}/src/format.cc)

    target_include_directories(fmt PRIVATE
        ${LIBFMT_DIR}/include
    )

    target_compile_options(fmt PRIVATE
        "-fno-exceptions"
        "-UNDEBUG"
    )

    # Android GTEST
    add_library(gtest STATIC ${LIBGTEST_DIR}/src/gtest-all.cc)

    target_include_directories(gtest PRIVATE
        ${LIBGTEST_DIR}
        ${LIBGTEST_DIR}/include
    )

    target_link_libraries(gtest PRIVATE pthread)

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
        ${BISON_parser_OUTPUTS})

    target_include_directories(aidl-common PRIVATE
        ${AIDL_DIR}
        ${LIBLOG_DIR}/include
        ${LIBBASE_DIR}/include
        ${LIBFMT_DIR}/include
        ${LIBGTEST_DIR}/include
        ${GENERATED_DIR}
    )

    target_compile_options(aidl-common PRIVATE
        -O0 -g -fpermissive -Wall -Wextra -std=c++17 -D__linux__
    )

    target_link_libraries(aidl-common PRIVATE
        base
        cutils
        gtest
        fmt
    )

    add_executable(aidl ${AIDL_DIR}/main.cpp)

    target_include_directories(aidl PRIVATE
        ${AIDL_DIR}
        ${LIBLOG_DIR}/include
        ${LIBBASE_DIR}/include
        ${LIBFMT_DIR}/include
    )

    target_compile_options(aidl PRIVATE
        -O0 -g -fpermissive -Wall -Wextra -std=c++17 -D__linux__
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
        -O0 -g -fpermissive -Wall -Wextra -std=c++17 -D__linux__ -DAIDL_CPP_BUILD
    )

    target_link_libraries(aidl-cpp PRIVATE
        aidl-common
        base
        log
    )
endif ()

if (BUILD_BINDER_DEVICE_UTILITY)
    add_executable(binder-device
        ${TOOLS_DIR}/BinderDevice.c
    )

    # Install the binder-device binary
    install(
        TARGETS
        binder-device

        RUNTIME
        DESTINATION ${CMAKE_INSTALL_BINDIR}
    )
endif ()

include(${CMAKE_CURRENT_LIST_DIR}/host/CMakeLists.inc)

