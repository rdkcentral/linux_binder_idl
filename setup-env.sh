#!/bin/sh

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

# ** @brief: Build linux binder idl module.
# *          This is basically to build the binder and example modules for host machine.
# *
# * Usage:
# *   source set-env.sh <Target lib arch version> <Install directory>
# *
# * Argument1 : Target lib ARCH version. The values are "32" or "64". The default target lib version is "64" bit.
# * Argument2 : CMake install directory. The default CMake installation path is "${PWD}/local".
# *
# * Following are the execution state flow of this build script
# *    1) Clone the android binder repositories from list ${REPOSITORIES} to the tag ${TAG}=android-13.0.0_r74
# *    2) The patches will be applied from ./patches/
# *    3) Call cmake to build the binder module for linux host machine.
# *       This will also, build the aidl/aidl-cpp utility for host/linux to generate stubs and
# *       proxies from .aidl file. Following are the generated binaries and libraries
# *           liblog
# *           libbase
# *           libcutils_sockets
# *           libcutils
# *           libutils
# *           libbinder
# *           servicemanager
# *    4) Also, builds FWManager service, client example binaries for binder aidl. Following are the generated
# *       binder example binaries
# *           FWManagerService
# *           FWManagerClient
# *    5) The generated bins, libs and headers will be installed in ${INSTALL_DIR}.
# *

###########################################################
# Print info message
###########################################################
LOGI() {
    echo ${LOG_INFO} ${LOG_TAG} ${1}
}

###########################################################
# Print error message
###########################################################
LOGE() {
    echo ${LOG_ERROR} ${LOG_TAG} ${1}
}

# Define and export global variables
#export WORK_DIR=`pwd`
export WORK_DIR=$(dirname "$(realpath "$0")")

export ANDROID_DIR="${WORK_DIR}/android"
export BUILD_DIR="${WORK_DIR}/out"

# Example code
export EXAMPLE_DIR="${WORK_DIR}/example"
export EXAMPLE_OUT_DIR="${EXAMPLE_DIR}/out"

# AIDL generator tool
export AIDL_GEN_DIR="${WORK_DIR}/aidl-generator"
export AIDL_GEN_OUT_DIR="${AIDL_GEN_DIR}/out"

if [ -z "$1" ]; then
    LOGI "Setting default target binder lib version as 64 bit"
    export TARGET_LIB_VERSION="64"
else
    LOGI "Setting target binder lib version as $1 bit"
    export TARGET_LIB_VERSION="$1"
fi

if [ -z "$2" ]; then
    # Modify this if want to change the install directory
    LOGI "Setting default CMake Install directory as $WORK_DIR/local"
    export INSTALL_DIR="$WORK_DIR/local"
else
    LOGI "Setting CMake Install directory as $2"
    export INSTALL_DIR="$2"
fi

# Basic commands
RM="rm -rf"
MKDIR="mkdir -p"
MAKE="make"
CMAKE="cmake"
GIT="git"
CD="cd"

LOG_TAG="<BINDERLINUX>"
LOG_INFO="<INFO>"
LOG_ERROR="<ERROR>"

# Android TAG
TAG="android-13.0.0_r74"

# Android AOSP binder repositories
REPOSITORIES="
    https://android.googlesource.com/platform/frameworks/native
    https://android.googlesource.com/platform/system/tools/aidl
    https://android.googlesource.com/platform/external/fmtlib
    https://android.googlesource.com/platform/system/logging
    https://android.googlesource.com/platform/system/libbase
    https://android.googlesource.com/platform/system/core
    https://android.googlesource.com/platform/external/googletest
    https://android.googlesource.com/platform/prebuilts/build-tools
"

###########################################################
# pushd function
###########################################################
PUSHD() {
    stack="$PWD $stack"
    cd "$1" || return 1
}


###########################################################
# popd function
###########################################################
POPD() {
    if [ -n "$stack" ]; then
        dir="${stack%% *}"
        stack="${stack#* }"
        cd "$dir" || return 1
    else
        echo "Stack is empty"
        return 1
    fi
}

###########################################################
# Clone android repos
###########################################################
clone_android_binder_repo() {

    LOGI "Clone android repositories"
    ${CD} ${WORK_DIR}

    # Remove existing android directory
    ${RM} ${ANDROID_DIR}
    ${MKDIR} ${ANDROID_DIR} && ${CD} ${ANDROID_DIR}

    for R in ${REPOSITORIES}; do
        # Clone the repo using - git clone ${GIT_OPTIONS} -b ${TAG} ${R}
        ${GIT} clone -c advice.detachedHead=false --depth 1 -b ${TAG} ${R}
        if [ $? -ne 0 ]; then
            LOGE "Failed to clone android repositories"
            ${CD} ${WORK_DIR}
            return 1
        fi

        # Apply the patches for patch folder to cloned repo
        BASENAME=`basename ${R}`
        LOGI "Applying patch to ${BASENAME}"

        PATCH="${WORK_DIR}/patches/${BASENAME}.patch"
        if [ -f ${PATCH} ]; then
            LOGI "Applying : ${PATCH}"
            PUSHD ${BASENAME}
            ${GIT} apply ${PATCH}
            if [ $? -ne 0 ]; then
                LOGE "Failed applying patch to ${BASENAME}"
                ${CD} ${WORK_DIR}
                return 2
            fi
            POPD
        fi
    done

    LOGI "Successfully cloned android repositories"
    ${CD} ${WORK_DIR}
}

###########################################################
# Clone android liblog repo
###########################################################
clone_android_liblog_repo() {

    LOGI "Clone android liblog repository"
    ${CD} ${WORK_DIR}

    # Remove existing android directory
    ${RM} ${ANDROID_DIR}
    ${MKDIR} ${ANDROID_DIR} && ${CD} ${ANDROID_DIR}

    LOGI "Use Google android liblog repo"
    LIBLOG_REPO="https://android.googlesource.com/platform/system/logging"

    # Clone the repo using - git clone ${GIT_OPTIONS} -b ${TAG} ${REPO}
    ${GIT} clone -c advice.detachedHead=false --depth 1 -b ${TAG} ${LIBLOG_REPO}
    if [ $? -ne 0 ]; then
        LOGE "Failed to clone android liblog repository"
        ${CD} ${WORK_DIR}
        return 1
    fi

    # Apply the patches for patch folder to cloned repo
    BASENAME=`basename ${LIBLOG_REPO}`
    LOGI "Applying patch to ${BASENAME}"

    PATCH="${WORK_DIR}/patches/${BASENAME}.patch"
    if [ -f ${PATCH} ]; then
        LOGI "Applying : ${PATCH}"
        PUSHD ${BASENAME}
        ${GIT} apply ${PATCH}
        if [ $? -ne 0 ]; then
            LOGE "Failed applying patch to ${BASENAME}"
            ${CD} ${WORK_DIR}
            return 2
        fi
        POPD
    fi

    LOGI "Successfully cloned android liblog repository"
    ${CD} ${WORK_DIR}
}

###########################################################
# Build linux binder module
###########################################################
build_linux_binder() {

    LOGI "Build linux binder modules"
    ${CD} ${WORK_DIR}

    # Remove existing build directory
    ${RM} ${BUILD_DIR}
    ${MKDIR} ${BUILD_DIR}

    #${CD} ${BUILD_DIR} && ${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DBUILD_ENV_HOST=ON -DTARGET_LIB64_VERSION=ON ${WORK_DIR} && ${MAKE} install -j `nproc`
    #${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} ${WORK_DIR} && ${MAKE} install -j `nproc`

    ${CD} ${BUILD_DIR}
    if [ "${TARGET_LIB_VERSION}" = "64" ]; then
        LOGI "Build 64Bit binder library for host machine"
        ${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DBUILD_ENV_HOST=ON -DTARGET_LIB64_VERSION=ON ${WORK_DIR} && ${MAKE} install -j `nproc`
    else
        LOGI "Build 32Bit binder library for host machine"
        ${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DBUILD_ENV_HOST=ON ${WORK_DIR} && ${MAKE} install -j `nproc`
    fi
    if [ $? -ne 0 ]; then
        LOGE "Failed to build the linux binder libraries and binaries"
        ${CD} ${WORK_DIR}
        return 3
    fi

    LOGI "Successfully build the linux binder libraries and binaries"
    ${CD} ${WORK_DIR}
}

###########################################################
# Build linux binder examples
###########################################################
build_binder_examples() {

    LOGI "Build linux binder examples"
    LOGI "Please make sure you have build the linux binder modules"
    LOGI "If not please run *build_linux_binder* to build the linux binder modules"
    ${CD} ${WORK_DIR}

    # Remove existing example out directory
    ${RM} ${EXAMPLE_OUT_DIR}
    ${MKDIR} ${EXAMPLE_OUT_DIR}

    ${CD} ${EXAMPLE_OUT_DIR}
    #${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DBUILD_USING_AIDL_UTILITY=ON ${EXAMPLE_DIR} && ${MAKE} install -j `nproc`
    ${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} ${EXAMPLE_DIR} && ${MAKE} install -j `nproc`
    if [ $? -ne 0 ]; then
        LOGE "Failed to build the linux binder examples"
        ${CD} ${WORK_DIR}
        return 4
    fi

    LOGI "Successfully build the linux binder examples"
    ${CD} ${WORK_DIR}
}

###########################################################
# Build aidl generator tool
###########################################################
build_aidl_generator_tool() {

    LOGI "Build linux binder idl generator tool"
    ${CD} ${WORK_DIR}

    # Remove existing aidl generator build directory
    ${RM} ${AIDL_GEN_OUT_DIR}
    ${MKDIR} ${AIDL_GEN_OUT_DIR}

    ${CD} ${AIDL_GEN_OUT_DIR}
    ${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} ${AIDL_GEN_DIR} && ${MAKE} install -j `nproc`
    #${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DBUILD_ENV_HOST=ON -DBUILD_STATIC_LIB=ON ${WORK_DIR} && ${MAKE} aidl -j `nproc`
    if [ $? -ne 0 ]; then
        LOGE "Failed to build the linux binder idl generator tool"
        ${CD} ${WORK_DIR}
        return 5
    fi

    LOGI "Successfully build the linux binder idl generator tool"
    ${CD} ${WORK_DIR}
}

###########################################################
# Build linux binder-device tool to create binder node
###########################################################
build_binder_device_tool() {

    LOGI "Build linux binder device tool to create binder node"
    ${CD} ${WORK_DIR}

    # Remove existing build directory
    ${RM} ${BUILD_DIR}
    ${MKDIR} ${BUILD_DIR}

    ${CD} ${BUILD_DIR}
    ${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DBUILD_ENV_HOST=ON -DBUILD_BINDER_DEVICE_UTILITY=ON ${WORK_DIR} && ${MAKE} binder-device -j `nproc`
    if [ $? -ne 0 ]; then
        LOGE "Failed to build the linux binder device tool"
        ${CD} ${WORK_DIR}
        return 6
    fi

    LOGI "Successfully build the linux binder device tool"
    ${CD} ${WORK_DIR}
}

###########################################################
# Clean build directory
###########################################################
clean_build() {

    LOGI "Clean build directory"
    ${CD} ${WORK_DIR}

    # Remove build directory
    ${RM} ${BUILD_DIR}
    if [ $? -ne 0 ]; then
        LOGE "Failed to clean build directory"
        return 7
    fi

    LOGI "Successfully cleaned build directory"
}

###########################################################
# Clean example build directory
###########################################################
clean_example_build() {

    LOGI "Clean example build directory"
    ${CD} ${WORK_DIR}

    # Remove example out directory
    ${RM} ${EXAMPLE_OUT_DIR}
    if [ $? -ne 0 ]; then
        LOGE "Failed to clean example build directory"
        return 8
    fi

    LOGI "Successfully cleaned example build directory"
}

###########################################################
# Clean aidl generator build directory
###########################################################
clean_aidl_generator_build() {

    LOGI "Clean aidl generator build directory"
    ${CD} ${WORK_DIR}

    # Remove aidl generator out directory
    ${RM} ${AIDL_GEN_OUT_DIR}
    if [ $? -ne 0 ]; then
        LOGE "Failed to clean aidl generator build directory"
        return 8
    fi

    LOGI "Successfully cleaned aidl generator build directory"
}

###########################################################
# Clean android cloned directory
###########################################################
clean_android_clone() {

    LOGI "Clean android cloned directory"
    ${CD} ${WORK_DIR}

    # Remove android cloned directory
    ${RM} ${ANDROID_DIR}
    if [ $? -ne 0 ]; then
        LOGE "Failed to clean android cloned directory"
        return 9
    fi

    LOGI "Successfully cleaned android cloned directory"
}

###########################################################
# Clean android and example build directory
###########################################################
clean_build_all() {

    LOGI "Clean all build directory"
    clean_build
    clean_example_build
    clean_aidl_generator_build
    LOGI "Successfully cleaned all build directory"
}

###########################################################
# Clean android and example build dir and clone directory
###########################################################
clean_all() {

    LOGI "Clean all build directory and clone directory"
    clean_build
    clean_example_build
    clean_aidl_generator_build
    clean_android_clone
    LOGI "Successfully cleaned all build directory and clone directory"
}

###########################################################
# Build android liblog
###########################################################
build_liblog() {

    LOGI "Build android liblog library"
    ${CD} ${WORK_DIR}

    # Remove existing build out directory
    ${RM} ${BUILD_DIR}
    ${MKDIR} ${BUILD_DIR}

    ${CD} ${BUILD_DIR}
    ${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DBUILD_ENV_HOST=ON ${WORK_DIR} && ${MAKE} log -j `nproc`
    if [ $? -ne 0 ]; then
        LOGE "Failed to build android liblog library"
        ${CD} ${WORK_DIR}
        return 10
    fi

    LOGI "Successfully build android liblog library"
    ${CD} ${WORK_DIR}
}

###########################################################
# Build libbase
###########################################################
build_libbase() {

    LOGI "Build libbase library"
    ${CD} ${WORK_DIR}

    # Remove existing build out directory
    ${RM} ${BUILD_DIR}
    ${MKDIR} ${BUILD_DIR}

    ${CD} ${BUILD_DIR}
    ${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DBUILD_ENV_HOST=ON ${WORK_DIR} && ${MAKE} base -j `nproc`
    if [ $? -ne 0 ]; then
        LOGE "Failed to build libbase library"
        ${CD} ${WORK_DIR}
        return 11
    fi

    LOGI "Successfully build libbase library"
    ${CD} ${WORK_DIR}
}

###########################################################
# Build libcutils
###########################################################
build_libcutils() {

    LOGI "Build libcutils library"
    ${CD} ${WORK_DIR}

    # Remove existing build out directory
    ${RM} ${BUILD_DIR}
    ${MKDIR} ${BUILD_DIR}

    ${CD} ${BUILD_DIR}
    ${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DBUILD_ENV_HOST=ON ${WORK_DIR} && ${MAKE} cutils -j `nproc`
    if [ $? -ne 0 ]; then
        LOGE "Failed to build libcutils library"
        ${CD} ${WORK_DIR}
        return 12
    fi

    LOGI "Successfully build libcutils library"
    ${CD} ${WORK_DIR}
}

###########################################################
# Build libutils
###########################################################
build_libutils() {

    LOGI "Build libutils library"
    ${CD} ${WORK_DIR}

    # Remove existing build out directory
    ${RM} ${BUILD_DIR}
    ${MKDIR} ${BUILD_DIR}

    ${CD} ${BUILD_DIR}
    ${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DBUILD_ENV_HOST=ON ${WORK_DIR} && ${MAKE} utils -j `nproc`
    if [ $? -ne 0 ]; then
        LOGE "Failed to build libutils library"
        ${CD} ${WORK_DIR}
        return 13
    fi

    LOGI "Successfully build libutils library"
    ${CD} ${WORK_DIR}
}

###########################################################
# Build binder library
###########################################################
build_libbinder() {

    LOGI "Build binder library"
    ${CD} ${WORK_DIR}

    # Remove existing build out directory
    ${RM} ${BUILD_DIR}
    ${MKDIR} ${BUILD_DIR}

    ${CD} ${BUILD_DIR}
    if [ "${TARGET_LIB_VERSION}" = "64" ]; then
        LOGI "Build 64Bit binder library"
        ${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DBUILD_ENV_HOST=ON -DTARGET_LIB64_VERSION=ON ${WORK_DIR} && ${MAKE} binder -j `nproc`
    else
        LOGI "Build 32Bit binder library"
        ${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DBUILD_ENV_HOST=ON ${WORK_DIR} && ${MAKE} binder -j `nproc`
    fi
    if [ $? -ne 0 ]; then
        LOGE "Failed to build binder library"
        ${CD} ${WORK_DIR}
        return 14
    fi

    LOGI "Successfully build binder library"
    ${CD} ${WORK_DIR}
}

###########################################################
# Build servicemanager
###########################################################
build_servicemanager() {

    LOGI "Build servicemanager"
    ${CD} ${WORK_DIR}

    # Remove existing build out directory
    ${RM} ${BUILD_DIR}
    ${MKDIR} ${BUILD_DIR}

    ${CD} ${BUILD_DIR}
    ${CMAKE} -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} -DBUILD_ENV_HOST=ON ${WORK_DIR} && ${MAKE} servicemanager -j `nproc`
    if [ $? -ne 0 ]; then
        LOGE "Failed to build servicemanager"
        ${CD} ${WORK_DIR}
        return 15
    fi

    LOGI "Successfully build servicemanager"
    ${CD} ${WORK_DIR}
}
