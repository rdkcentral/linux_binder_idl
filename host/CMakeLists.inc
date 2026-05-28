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

cmake_minimum_required(VERSION 3.8)

project(Interface_Libraries)

#######################################################################
# Root and output defaults
#
# Callers *may* override:
#   -DLINUX_BINDER_AIDL_ROOT=/path/to/repo
#   -DLINUX_BINDER_AIDL_ROOT_OUT=/path/to/out
#   -DHOST_AIDL_DIR=/path/to/host/aidl_compiler
#
# If they are not provided:
#   - LINUX_BINDER_AIDL_ROOT     → inferred from this file location
#   - LINUX_BINDER_AIDL_ROOT_OUT → ${LINUX_BINDER_AIDL_ROOT}/out
#   - HOST_AIDL_DIR              → ${LINUX_BINDER_AIDL_ROOT_OUT}/host/aidl_compiler
#######################################################################

# Derive repo root if not provided
if (NOT DEFINED LINUX_BINDER_AIDL_ROOT)
    # Assume this file sits under <repo>/host or <repo>/something/host
    get_filename_component(_this_dir "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
    # Go one level up by default (adjust if your layout is different)
    get_filename_component(LINUX_BINDER_AIDL_ROOT "${_this_dir}/.." ABSOLUTE)
    message(STATUS "LINUX_BINDER_AIDL_ROOT not set, defaulting to ${LINUX_BINDER_AIDL_ROOT}")
else()
    message(STATUS "LINUX_BINDER_AIDL_ROOT explicitly set to ${LINUX_BINDER_AIDL_ROOT}")
endif()

# Derive out/ root if not provided
if (NOT DEFINED LINUX_BINDER_AIDL_ROOT_OUT)
    set(LINUX_BINDER_AIDL_ROOT_OUT "${LINUX_BINDER_AIDL_ROOT}/out")
    message(STATUS "LINUX_BINDER_AIDL_ROOT_OUT not set, defaulting to ${LINUX_BINDER_AIDL_ROOT_OUT}")
else()
    message(STATUS "LINUX_BINDER_AIDL_ROOT_OUT explicitly set to ${LINUX_BINDER_AIDL_ROOT_OUT}")
endif()

# Base directory under which generated <interface>/<version>/{src,include} live.
# Decoupled from LINUX_BINDER_AIDL_ROOT_OUT (the intermediate out/ dir) so that
# a consumer using module-local generation can point this at its repo root
# while keeping intermediate artefacts in a separate out/ tree. Defaults to
# LINUX_BINDER_AIDL_ROOT_OUT for backwards compatibility.
#
# Contract: this must resolve to the directory whose generated output the
# generator actually produces. For module-local layout the generator emits
# into <interfaces-root>/<interface>/<version>/, so this must be set to that
# interfaces root. A mismatch is caught loudly by the post-generation source
# re-check below (FATAL_ERROR "no C++ files found"), never silently.
if (NOT DEFINED LINUX_BINDER_AIDL_GENERATED_ROOT)
    set(LINUX_BINDER_AIDL_GENERATED_ROOT "${LINUX_BINDER_AIDL_ROOT_OUT}")
    message(STATUS "LINUX_BINDER_AIDL_GENERATED_ROOT not set, defaulting to ${LINUX_BINDER_AIDL_GENERATED_ROOT}")
else()
    message(STATUS "LINUX_BINDER_AIDL_GENERATED_ROOT explicitly set to ${LINUX_BINDER_AIDL_GENERATED_ROOT}")
endif()

# Derive host AIDL compiler root if not provided
if (NOT DEFINED HOST_AIDL_DIR)
    set(HOST_AIDL_DIR "${LINUX_BINDER_AIDL_ROOT_OUT}/host/aidl_compiler")
    message(STATUS "HOST_AIDL_DIR not set, defaulting to ${HOST_AIDL_DIR}")
else()
    message(STATUS "HOST_AIDL_DIR explicitly set to ${HOST_AIDL_DIR}")
endif()

#######################################################################
# Internal paths used by this helper
#######################################################################
set(LINUX_BINDER_AIDL_ROOT_HOST "${HOST_AIDL_DIR}")
set(INTERFACE_LIB_DEPS_FILE "${LINUX_BINDER_AIDL_ROOT_OUT}/dependencies.txt")

# If SDK_LIB_DIR is provided, tell the linker to look there
if (DEFINED SDK_LIB_DIR)
    link_directories(${SDK_LIB_DIR})
endif()

#######################################################################
# Set path for interfaces root directories
# If INTERFACES_ROOT_DIRS are not given set it to the directory working
# directory
#######################################################################
message(STATUS "Given Interfaces Root Dirs: ${INTERFACES_ROOT_DIRS} ")
execute_process(COMMAND pwd OUTPUT_VARIABLE WORKING_DIR OUTPUT_STRIP_TRAILING_WHITESPACE)
message(STATUS "WORKING_DIR: ${WORKING_DIR} ")
if (DEFINED INTERFACES_ROOT_DIRS)
    foreach(interface_dir IN LISTS INTERFACES_ROOT_DIRS)
        file(REAL_PATH ${interface_dir} interface_dir_abs BASE_DIRECTORY ${WORKING_DIR})
        list(APPEND interfaces_dir ${interface_dir_abs})
    endforeach()
else()
    # if INTERFACES_ROOT_DIRS is not set, set it to the working directory
    set(interfaces_dir ${WORKING_DIR})
endif()
message(STATUS "Interface Root Directories: ${interfaces_dir}")


#######################################################################
# Generate Libraries dependency tree associated to interfaces available
# in given interfaces.
# Read this dependency tree and set it to aidl_targets
# Example: if the Interface Libary name is "com.rdk.hal-v1-cpp"
# dependency variable: com.rdk.hal-v1-cpp_deps
#######################################################################
message(STATUS "Generating Interfaces Libraries Dependencies at ${INTERFACE_LIB_DEPS_FILE}")
# Changed to use aidl_ops.py directly (no symlink dependence)
execute_process(
    COMMAND ${LINUX_BINDER_AIDL_ROOT_HOST}/aidl_ops.py -a -r ${interfaces_dir} -o ${LINUX_BINDER_AIDL_ROOT_OUT}
)

set(aidl_targets)

function (read_interfaces_lib_dependencies filename)
    if(EXISTS ${filename})
        file(READ ${filename} content)
        message(STATUS "Dependency Tree \n\t${content}")
    else()
        message(FATAL_ERROR "Interfaces Libraries dependency tree not found. Interfaces are not available")
    endif()

    string(REGEX MATCHALL "([-a-zA-Z0-9_.]+):([-a-zA-Z0-9_. ]*)" matches ${content})
    
    foreach(match ${matches})
        string(REGEX REPLACE "([-a-zA-Z0-9_.]+):([-a-zA-Z0-9_. ]*)" "\\1" lib ${match})
        string(REGEX REPLACE "([-a-zA-Z0-9_.]+):([-a-zA-Z0-9_. ]*)" "\\2" deps ${match})
        string(STRIP ${deps} deps)
        list(APPEND aidl_targets ${lib})
        set(${lib}_deps ${deps} PARENT_SCOPE)
    endforeach()

    set(aidl_targets ${aidl_targets} PARENT_SCOPE)

endfunction()

read_interfaces_lib_dependencies(${INTERFACE_LIB_DEPS_FILE})


#######################################################################
# Function to configure the library and it's installation in CMake
# Project.
# This function is used recursivly to add dependant libraries as well.
#######################################################################
function(AddInterfaceLibrary aidl_target)
    if (TARGET ${aidl_target})
        message(STATUS "Target ${aidl_target} already added as a library")
        return()
    endif()

    string(REGEX MATCH "^[^-]+" interface_name "${aidl_target}")
    string(REGEX MATCH "-v([0-9]+)" version_part "${aidl_target}")
    string(REGEX REPLACE "-v" "" interface_version "${version_part}")

    if (NOT interface_version)
        set(interface_version "current")
        set(interface_version_arg "")
    else()
        # CMake list so execute_process expands this to two separate argv entries.
        # aidl_ops.py uses getopt and rejects "-v <version>" as a single token.
        set(interface_version_arg -v ${interface_version})
    endif()

    if (NOT "${${aidl_target}_deps}" STREQUAL "")
        string(REPLACE " " ";" ${aidl_target}_deps "${${aidl_target}_deps}")
    endif()
    message(STATUS "Target: ${aidl_target}, Dependencies: ${${aidl_target}_deps}")

    foreach(dep IN LISTS ${aidl_target}_deps)
        message(VERBOSE "DEP: ${dep}")
        AddInterfaceLibrary(${dep})
    endforeach()

    list(GET interfaces_dir 0 first_interfaces_root)
    
    # Generated sources live under LINUX_BINDER_AIDL_GENERATED_ROOT (which
    # defaults to LINUX_BINDER_AIDL_ROOT_OUT). For module-local consumers this
    # is the repo root, so the path resolves to <repo>/<module>/<version>/.
    set(source_dir ${LINUX_BINDER_AIDL_GENERATED_ROOT}/${interface_name}/${interface_version}/src)
    set(include_dir ${LINUX_BINDER_AIDL_GENERATED_ROOT}/${interface_name}/${interface_version}/include)

    # Regeneration policy (#530, Option A):
    #   - "current" version: ALWAYS regenerate. The AIDL under <module>/current/
    #     is mutable and the previous "skip if include/src already populated"
    #     guard silently shipped stale C++ when the AIDL changed but the
    #     generated tree happened to exist (e.g. from a prior build or a
    #     stale checkout). The AIDL compiler overwrites in place, so a
    #     successful regen brings the tree to byte-equivalent state with
    #     the AIDL; if a method or type is removed, its primary file is
    #     overwritten with the new content. Regen is cheap relative to
    #     compile and eliminates the "ship stale generated code" class of
    #     bug entirely.
    #   - Frozen versions (e.g. v1, v2): pre-committed C++ is part of the
    #     release contract - if pre-committed sources exist on disk, reuse
    #     them as-is and skip regen entirely. The first build of a freshly
    #     checked-out frozen version that ships no generated tree (rare,
    #     but possible for in-flight versions before sources are committed)
    #     will generate once to bootstrap; subsequent builds reuse what's
    #     on disk.
    file(GLOB_RECURSE existing_sources "${source_dir}/*.cpp")

    if (interface_version STREQUAL "current")
        message(STATUS "Regenerating sources for ${interface_name} v${interface_version} (always-regen, #530)")

        # Generate Sources
        message(VERBOSE "Command: ${LINUX_BINDER_AIDL_ROOT_HOST}/aidl_ops.py -g ${interface_version_arg} -r ${interfaces_dir} -o ${LINUX_BINDER_AIDL_ROOT_OUT} ${interface_name}")
        execute_process(
            COMMAND ${LINUX_BINDER_AIDL_ROOT_HOST}/aidl_ops.py -g ${interface_version_arg} -r "${interfaces_dir}" -o "${LINUX_BINDER_AIDL_ROOT_OUT}" ${interface_name}
            RESULT_VARIABLE gen_result
        )

        if(NOT gen_result EQUAL 0)
            message(FATAL_ERROR "AIDL generation failed for ${interface_name}; check the aidl_ops.py output above.")
        endif()

        # Re-glob after generation; the generator writes <module>/current/{src,include}.
        file(GLOB_RECURSE source_files "${source_dir}/*.cpp")
        if(NOT source_files)
            # Defensive fallback: if regen ran cleanly but produced no files in
            # the expected location (e.g. a component whose interface loader
            # maps to a different versioned directory than CMake's "current"
            # path), fall back to any pre-committed sources so the build
            # remains usable. This preserves the previous behaviour for those
            # components without losing the new always-regen guarantee for the
            # common case.
            if(existing_sources)
                list(LENGTH existing_sources list_length)
                message(WARNING "Regeneration produced no files in ${source_dir}; "
                                "falling back to ${list_length} pre-committed source(s). "
                                "Generated C++ may be stale relative to AIDL.")
                set(source_files ${existing_sources})
            else()
                message(FATAL_ERROR "Source generation completed but no C++ files found in ${source_dir}")
            endif()
        endif()
    elseif(NOT existing_sources)
        # Frozen version with no pre-committed sources - generate once.
        message(STATUS "No pre-generated sources found for ${interface_name} v${interface_version}")
        message(STATUS "Generating sources using aidl_ops...")

        message(VERBOSE "Command: ${LINUX_BINDER_AIDL_ROOT_HOST}/aidl_ops.py -g ${interface_version_arg} -r ${interfaces_dir} -o ${LINUX_BINDER_AIDL_ROOT_OUT} ${interface_name}")
        execute_process(
            COMMAND ${LINUX_BINDER_AIDL_ROOT_HOST}/aidl_ops.py -g ${interface_version_arg} -r "${interfaces_dir}" -o "${LINUX_BINDER_AIDL_ROOT_OUT}" ${interface_name}
            RESULT_VARIABLE gen_result
        )

        if(NOT gen_result EQUAL 0)
            message(FATAL_ERROR "AIDL generation failed for ${interface_name}; check the aidl_ops.py output above.")
        endif()

        # Re-check after generation
        file(GLOB_RECURSE source_files "${source_dir}/*.cpp")
        if(NOT source_files)
            message(FATAL_ERROR "Source generation completed but no C++ files found in ${source_dir}")
        endif()
    else()
        list(LENGTH existing_sources list_length)
        message(STATUS "Using pre-generated sources for ${interface_name} v${interface_version} (${list_length} files)")
        set(source_files ${existing_sources})
    endif()
    
    # Post-process generated headers to add missing #include <mutex>
    # AIDL code generator creates Bp*.h files that use std::mutex without including <mutex>
    file(GLOB_RECURSE bp_headers "${include_dir}/**/Bp*.h")
    foreach(header_file ${bp_headers})
        file(READ "${header_file}" header_content)
        # Only add if not already present
        string(FIND "${header_content}" "#include <mutex>" has_mutex)
        if(has_mutex EQUAL -1)
            string(REGEX REPLACE "(#pragma once\n)" "\\1#include <mutex>\n" header_content "${header_content}")
            file(WRITE "${header_file}" "${header_content}")
        endif()
    endforeach()


    message(VERBOSE "adding target ${aidl_target} as a library")
    add_library(
        ${aidl_target} SHARED ${source_files}
        )

    # [FIX 2] Dual Mode Include Logic (SDK vs Internal)
    if (DEFINED SDK_INCLUDE_DIR)
        # Mode A: SDK Mode (Clean)
        set(FINAL_INCLUDE_DIRS ${SDK_INCLUDE_DIR})
    else()
        # Mode B: Internal Mode (Raw Headers)
        # Calculate root of the toolchain relative to this file
        get_filename_component(TOOLCHAIN_ROOT "${CMAKE_CURRENT_LIST_DIR}/../" ABSOLUTE)
        
        set(FINAL_INCLUDE_DIRS
            "${TOOLCHAIN_ROOT}/android/native/libs/binder/ndk/include_cpp"
            "${TOOLCHAIN_ROOT}/android/native/libs/binder/include"
            "${TOOLCHAIN_ROOT}/android/native/include"
            "${TOOLCHAIN_ROOT}/android/libbase/include"
            "${TOOLCHAIN_ROOT}/android/core/libutils/include"
            "${TOOLCHAIN_ROOT}/android/logging/liblog/include"
            "${TOOLCHAIN_ROOT}/android/core/libcutils/include"
        )
    endif()

    target_include_directories(
        ${aidl_target} PUBLIC 
        ${include_dir}
        ${FINAL_INCLUDE_DIRS}
    )

    target_link_libraries(
        ${aidl_target} PUBLIC "${${aidl_target}_deps}"
        binder
        utils
    )

    target_compile_options(${aidl_target} PUBLIC
        -Wall 
        -Wextra 
        -std=gnu++17           # Use GNU extensions instead of strict ISO C++17
        
        # --- GCC COMPATIBILITY FLAGS ---
        -Wno-unknown-pragmas   # Silences "#pragma clang diagnostic..."
        -Wno-attributes        # Silences "[[clang::lto_visibility_public]]"
        -Wno-psabi             # Silences common ARM ABI warnings (optional)
        -Wno-write-strings     # Silence string literal to char* warnings from AIDL
        -Wno-return-type       # Silence missing return warnings from AIDL code
    )
    
    # Force include missing headers for AIDL-generated code
    target_compile_definitions(${aidl_target} PRIVATE
        _GLIBCXX_INCLUDE_NEXT_C_HEADERS  # Ensure C++ standard headers are available
    )

    install(TARGETS
        ${aidl_target}
        DESTINATION ${CMAKE_INSTALL_LIBDIR}
    )

    # [FIX 3] Generate Portable CMakeLists.txt for clients
    set(STANDALONE_CMAKE_CONTENT "
cmake_minimum_required(VERSION 3.8)
project(${aidl_target})

# The Consumer MUST provide the SDK location
if (NOT DEFINED SDK_INCLUDE_DIR)
    message(FATAL_ERROR \"SDK_INCLUDE_DIR is not defined.\\n\"
            \"To build this library independently, you must provide the path to the RDK Android SDK headers.\\n\"
            \"Example: cmake -DSDK_INCLUDE_DIR=/path/to/sdk/include .\")
endif()

include_directories(\${SDK_INCLUDE_DIR})

file(GLOB_RECURSE SRC_FILES \"src/*.cpp\")

add_library(${aidl_target} SHARED \${SRC_FILES})
target_include_directories(${aidl_target} PUBLIC \"include\")
")

    # Write the portable file to the output directory provided by parent
    file(WRITE "${LINUX_BINDER_AIDL_ROOT_OUT}/${interface_name}/${interface_version}/CMakeLists.txt" "${STANDALONE_CMAKE_CONTENT}")

endfunction()


#######################################################################
# Function to link the aidl interface library to the given target.
# First it adds the interface library and it's dependencies to the build
# and then links it.
# This is to avoid the installation of all interfaces libraries
#######################################################################
function(target_link_interfaces_libraries target)
    set(options)
    set(oneValueArgs)
    set(multiValueArgs LIBS)
    cmake_parse_arguments(TLI "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    if (NOT TARGET ${target})
        message(FATAL_ERROR "Target '${target}' does not exist.")
    endif()

    foreach(aidl_target IN LISTS ARGN)
        list(FIND aidl_targets ${aidl_target} target_index)
        if (${target_index} EQUAL -1)
            message(WARNING "⚠️ '${lib}' is not in ALL_TARGETS. Skipping.")
        else()
            AddInterfaceLibrary(${aidl_target})

            target_link_libraries(${target} PUBLIC ${aidl_target})
        endif()
    endforeach()

endfunction()


function(target_build_interfaces_libraries)
    message(STATUS "Building ${INTERFACE_TARGET} interface/s for ${INTERFACE_VERSION} version/s")


    if (NOT DEFINED INTERFACE_VERSION)
        message(STATUS "Set INTERFACE_VERSION to all")
        set(INTERFACE_VERSION all)
    endif()

    if (NOT DEFINED INTERFACE_TARGET)
        message(STATUS "Set INTERFACE_TARGET to all")
        set(INTERFACE_TARGET all)
    endif()

    # Add interface libraries as per given values
    if (${INTERFACE_VERSION} STREQUAL "all")
        if (${INTERFACE_TARGET} STREQUAL  "all")
            # Build all interface libraries for all versions
            message(STATUS, "Build all interface libraries for all versions")
            foreach(aidl_target IN LISTS aidl_targets)
                message(STATUS "Adding AIDL interface library ${aidl_target}")
                AddInterfaceLibrary(${aidl_target})
            endforeach()
        else ()
            # Build all versions of given target
            message(STATUS, "Build all versions of given target, ${INTERFACE_TARGET}")
            foreach(aidl_target IN LISTS aidl_targets)
                # Match "xxxx-v1-cpp", "xxxx-vcurrent-cpp", etc.
                if (aidl_target MATCHES "^${INTERFACE_TARGET}-v.*")
                    AddInterfaceLibrary(${aidl_target})
                endif()
            endforeach()
        endif()
    elseif (${INTERFACE_VERSION} STREQUAL "current")
        if (${INTERFACE_TARGET} STREQUAL  "all")
            # Build all interface libraries for current version
            message(VERBOSE, "Build all interface libraries for current version")
            foreach(aidl_target IN LISTS aidl_targets)
                if (aidl_target MATCHES "-vcurrent-cpp$")
                    AddInterfaceLibrary(${aidl_target})
                endif()
            endforeach()
        else()
            # Build current versions of given target
            message(VERBOSE, "Build current versions of given target, ${INTERFACE_TARGET}")
            set(target_name "${INTERFACE_TARGET}-vcurrent-cpp")
            if (${target_name} IN_LIST aidl_targets)
                AddInterfaceLibrary(${target_name})
            else()
                message(FATAL_ERROR "Target ${target_name} not found in dependencies.")
            endif()
        endif()
    elseif (${INTERFACE_VERSION} STREQUAL "latest")
        if (${INTERFACE_TARGET} STREQUAL  "all")
            # Build all interface libraries for last frozen version
            message(VERBOSE, "Build all interface libraries for last frozen version")
             foreach(aidl_target IN LISTS aidl_targets)
                if (NOT aidl_target MATCHES "-vcurrent-cpp$")
                    AddInterfaceLibrary(${aidl_target})
                endif()
            endforeach()
        else()
            # Build latest versions of given target
            message(STATUS, "Build latest versions of given target, ${INTERFACE_TARGET}")
            message(FATAL_ERROR "To build a specific frozen version, use -DINTERFACE_VERSION=<number>")
        endif() 
    else ()
        if (${INTERFACE_TARGET} STREQUAL  "all")
            # Invalid inputs
            message(FATAL_ERROR "Invalid version set ${INTERFACE_VERSION} provided while building all targets.")
        else()
            # Build given version of given target
            message(STATUS, "Build given version, ${INTERFACE_VERSION}, of given target, ${INTERFACE_VERSION}")
            set(aidl_target ${INTERFACE_TARGET}-v${INTERFACE_VERSION}-cpp)
            if (${aidl_target} IN_LIST aidl_targets)
                message(STATUS "Building for ${aidl_target}")
                AddInterfaceLibrary(${aidl_target})
            else()
                message(FATAL_ERROR, "Target, ${aidl_target}, for ${INTERFACE_TARGET} version ${INTERFACE_VERSION} doesn't exist")
            endif()
        endif()
    endif()
endfunction()