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

# ** @brief : Build binder example module
# *           The cmake is used to build the FWManager binder example module.
# *

cmake_minimum_required (VERSION 3.8)

set(PACKAGE_NAME          "binder-example")
set(PACKAGE_VERSION       "2.0.0")
set(ANDROID_VERSION       "android-13.0.0_r74")
set(PACKAGE_STRING        "${PACKAGE_NAME} ${PACKAGE_VERSION}")

project(${PACKAGE_NAME} LANGUAGES C CXX)

find_package(PkgConfig)

project (binder_example)

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
# Suppress warnings from SDK headers about clang-specific attributes
add_compile_options(-Wno-attributes)
# Use prebuilt generated stubs and proxies
set(USE_PREBUILT_GEN_FILES ON)
if (BUILD_USING_AIDL_UTILITY)
    message("Use prebuilt generated stubs and proxies")
    # Build from .aidl file using aidl utility
    set(USE_PREBUILT_GEN_FILES OFF)
endif ()

###########################################################
# Set all the variables
###########################################################
set(BINDER_EXAMPLE_DIR "${CMAKE_SOURCE_DIR}")
set(BUILD_OUT_DIR "${CMAKE_SOURCE_DIR}/../out")

set(FWMANAGER_DIR ${BINDER_EXAMPLE_DIR}/FWManager)

set(GENERATED_DIR ${CMAKE_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${GENERATED_DIR})

# Modify the android build-tools path if necessary
set(ANDROID_BUILD_TOOLS_DIR "${CMAKE_SOURCE_DIR}/../android/build-tools/linux-x86")

if (NOT DEFINED CMAKE_INSTALL_LIBDIR)
    message("Set and create cmake install lib directory")
    set(CMAKE_INSTALL_LIBDIR ${CMAKE_INSTALL_PREFIX}/lib)
    file(MAKE_DIRECTORY ${CMAKE_INSTALL_LIBDIR})
    message("cmake install lib dir ${CMAKE_INSTALL_LIBDIR}")
endif ()

if (NOT DEFINED CMAKE_INSTALL_BINDIR)
    message("Set and create cmake install bin directory")
    set(CMAKE_INSTALL_BINDIR ${CMAKE_INSTALL_PREFIX}/bin)
    file(MAKE_DIRECTORY ${CMAKE_INSTALL_BINDIR})
    message("cmake install bin dir ${CMAKE_INSTALL_BINDIR}")
endif ()

if (NOT DEFINED CMAKE_INSTALL_INCDIR)
    message("Set and create cmake install include directory")
    set(CMAKE_INSTALL_INCDIR ${CMAKE_INSTALL_PREFIX}/include)
    file(MAKE_DIRECTORY ${CMAKE_INSTALL_INCDIR})
    message("cmake install header dir ${CMAKE_INSTALL_INCDIR}")
endif ()

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
            COMMAND ${BUILD_OUT_DIR}/aidl --lang=cpp -I${baseDir} "${baseDir}/${src}" --header_out ${GENERATED_DIR}/${aidlName}/include -o ${GENERATED_DIR}/${aidlName}
            DEPENDS ${baseDir}/${src}
            COMMENT "[AIDL] ${src} -> ${output}"
            VERBATIM
        )
        list(APPEND ${aidlName}_OUTPUTS ${output})
    endforeach(src)
endmacro()

# Set the common include path
include_directories(
    ${CMAKE_INSTALL_INCDIR}
)

# Set the library path
link_directories(
    ${CMAKE_INSTALL_LIBDIR}
)

# Add binder example directories
add_subdirectory(FWManager)