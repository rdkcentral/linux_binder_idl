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
# Set required path variabiles.
# LINUX_BINDER_AIDL_ROOT and LINUX_BINDER_AIDL_ROOT_OUT need to be set
# before including this script
#######################################################################
set(LINUX_BINDER_AIDL_ROOT_HOST ${LINUX_BINDER_AIDL_ROOT}/host)
set(AIDL_TOOL ${LINUX_BINDER_AIDL_ROOT}/local/bin/aidl)
set(INTERFACE_LIB_DEPS_FILE ${LINUX_BINDER_AIDL_ROOT_OUT}/dependencies.txt)

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
# Check if required host tool, aidl, is compiled. If mot compile it.
#######################################################################
#if(EXISTS ${AIDL_TOOL})
#    message(STATUS "using aidl tool from ${AIDL_TOOL}")
#else()
#    message(STATUS "Compiling aidl at ${AIDL_TOOL}")
#    execute_process(
#        COMMAND cmake -B ${LINUX_BINDER_AIDL_ROOT_OUT} -S ${LINUX_BINDER_AIDL_ROOT}/aidl-generator -D CMAKE_INSTALL_PREFIX=${LINUX_BINDER_AIDL_ROOT_OUT}/host
#    )
#    execute_process(
#        COMMAND make -C ${LINUX_BINDER_AIDL_ROOT_OUT} install -j `nproc`
#    )
#endif()


#######################################################################
# Generate Libraries dependency tree associated to interfaces available
# in given interfaces.
# Read this dependency tree and set it to aidl_targets
# Example: if the Interface Libary name is "com.rdk.hal-v1-cpp"
# dependency variable: com.rdk.hal-v1-cpp_deps
#######################################################################
message(STATUS "Generating Interfaces Libraries Dependencies at ${INTERFACE_LIB_DEPS_FILE}")
execute_process(
    COMMAND ${LINUX_BINDER_AIDL_ROOT_HOST}/aidl_ops -a -r ${interfaces_dir}
)

set(aidl_targets)

function (read_interfaces_lib_dependencies filename)
    if(EXISTS ${filename})
        file(READ ${filename} content)
        message(STATUS "Dependency Tree \n${content}")
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
        set(interface_version_arg "-v ${interface_version}")
    endif()

    if (NOT "${${aidl_target}_deps}" STREQUAL "")
        string(REPLACE " " ";" ${aidl_target}_deps "${${aidl_target}_deps}")
    endif()
    message(STATUS "Target: ${aidl_target}, Dependencies: ${${aidl_target}_deps}")

    foreach(dep IN LISTS ${aidl_target}_deps)
        message(STATUS "DEP: ${dep}")
        AddInterfaceLibrary(${dep})
    endforeach()

    list(GET interfaces_dir 0 first_interfaces_root)
    set(source_dir ${first_interfaces_root}/stable/generated/${interface_name}/${interface_version}/src)
    set(include_dir ${first_interfaces_root}/stable/generated/${interface_name}/${interface_version}/include)

    # Generate Sources
    message(STATUS "Command: ${LINUX_BINDER_AIDL_ROOT_HOST}/aidl_ops -g ${interface_version_arg} -r ${interfaces_dir} ${interface_name}")
    execute_process(
        COMMAND ${LINUX_BINDER_AIDL_ROOT_HOST}/aidl_ops -g ${interface_version_arg} -r "${interfaces_dir}" ${interface_name}
        )
    file(GLOB_RECURSE source_files "${source_dir}/*.cpp")

    message(STATUS "adding target ${aidl_target} as a library")
    add_library(
        ${aidl_target} SHARED ${source_files}
        )
    target_include_directories(
        ${aidl_target} PUBLIC ${include_dir}
        )
    target_link_libraries(
        ${aidl_target} PUBLIC "${${aidl_target}_deps}"
        binder
        utils
    )
    target_compile_options(${aidl_target} PUBLIC
    -Wall -Wextra -std=c++20
    )
    install(TARGETS
        ${aidl_target}
        DESTINATION ${CMAKE_INSTALL_LIBDIR}
    )
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
            # TODO
            # Build all versions of given target
            message(STATUS, "Build all versions of given target, ${INTERFACE_TARGET}")
        endif()
    elseif (${INTERFACE_VERSION} STREQUAL "current")
        if (${INTERFACE_TARGET} STREQUAL  "all")
            # TODO
            # Build all interface libraries for current version
            message(STATUS, "Build all interface libraries for current version")
        else()
            # TODO
            # Build current versions of given target
            message(STATUS, "Build current versions of given target, ${INTERFACE_TARGET}")
        endif()
    elseif (${INTERFACE_VERSION} STREQUAL "latest")
        if (${INTERFACE_TARGET} STREQUAL  "all")
            # TODO
            # Build all interface libraries for last frozen version
            message(STATUS, "Build all interface libraries for last frozen version")
        else()
            # TODO
            # Build latest versions of given target
            message(STATUS, "Build latest versions of given target, ${INTERFACE_TARGET}")
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
