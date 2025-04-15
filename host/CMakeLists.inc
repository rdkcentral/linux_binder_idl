cmake_minimum_required(VERSION 3.8)

project(Interface_Libraries)


#######################################################################
# Set required path variabiles.
# LINUX_BINDER_AIDL_ROOT and LINUX_BINDER_AIDL_ROOT_OUT need to be set
# before including this script
#######################################################################
set(LINUX_BINDER_AIDL_ROOT_HOST ${LINUX_BINDER_AIDL_ROOT}/host)
set(AIDL_TOOL ${LINUX_BINDER_AIDL_ROOT}/local/bin/aidl)
set(INTF_LIB_DEPS_FILE ${LINUX_BINDER_AIDL_ROOT_OUT}/dependencies.txt)

#######################################################################
# Set path for interfaces root directories
# If INTFS_ROOT_DIRS are not given set it to the directory working
# directory
#######################################################################
message(STATUS "Given Interfaces Root Dirs: ${INTFS_ROOT_DIRS} ")
execute_process(COMMAND pwd OUTPUT_VARIABLE WORKING_DIR OUTPUT_STRIP_TRAILING_WHITESPACE)
message(STATUS "WORKING_DIR: ${WORKING_DIR} ")
if (DEFINED INTFS_ROOT_DIRS)
    foreach(intf_dir IN LISTS INTFS_ROOT_DIRS)
        file(REAL_PATH ${intf_dir} intf_dir_abs BASE_DIRECTORY ${WORKING_DIR})
        list(APPEND intfs_dir ${intf_dir_abs})
    endforeach()
else()
    # if INTFS_ROOT_DIRS is not set, set it to the working directory
    set(intfs_dir ${WORKING_DIR})
endif()
message(STATUS "Interface Root Directories: ${intfs_dir}")


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
# Example: if the Interface Libary name is "com.rdk.hal-V1-cpp"
# dependency variable: com.rdk.hal-V1-cpp_deps
#######################################################################
message(STATUS "Generating Interfaces Libraries Dependencies at ${INTF_LIB_DEPS_FILE}")
execute_process(
    COMMAND ${LINUX_BINDER_AIDL_ROOT_HOST}/aidl_ops -a -r ${intfs_dir}
)

set(aidl_targets)

function (read_intfs_lib_dependencies filename)
    file(READ ${filename} content)
    message(STATUS "Dependency Tree \n${content}")

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

read_intfs_lib_dependencies(${INTF_LIB_DEPS_FILE})


#######################################################################
# Function to configure the library and it's installation in CMake
# Project.
# This function is used recursivly to add dependant libraries as well.
#######################################################################
function(AddIntfLibrary aidl_target)
    if (TARGET ${aidl_target})
        message(STATUS "Target ${aidl_target} already added as a library")
        return()
    endif()

    string(REGEX MATCH "^[^-]+" intf_name "${aidl_target}")
    string(REGEX MATCH "-V([0-9]+)" version_part "${aidl_target}")
    string(REGEX REPLACE "-V" "" intf_version "${version_part}")

    if (NOT "${${aidl_target}_deps}" STREQUAL "")
        string(REPLACE " " ";" ${aidl_target}_deps "${${aidl_target}_deps}")
    endif()
    message(STATUS "Target: ${aidl_target}, Dependencies: ${${aidl_target}_deps}")

    foreach(dep IN LISTS ${aidl_target}_deps)
        message(STATUS "DEP: ${dep}")
        AddIntfLibrary(${dep})
    endforeach()

    set(source_dir ${LINUX_BINDER_AIDL_ROOT_OUT}/aidl_gen/${aidl_target})
    set(include_dir ${source_dir}/include)
    
    # Generate Sources
    message(STATUS "Command: ${LINUX_BINDER_AIDL_ROOT_HOST}/aidl_ops -g -v ${intf_version} -d ${source_dir} -r ${intfs_dir} ${intf_name}")
    execute_process(
        COMMAND ${LINUX_BINDER_AIDL_ROOT_HOST}/aidl_ops -g -v ${intf_version} -d ${source_dir} -r "${intfs_dir}" ${intf_name}
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
function(target_link_intfs_libraries target)
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
            AddIntfLibrary(${aidl_target})

            target_link_libraries(${target} PUBLIC ${aidl_target})
        endif()
    endforeach()

endfunction()

