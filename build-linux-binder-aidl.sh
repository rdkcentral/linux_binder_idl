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

# ** @brief : Build linux binder idl.
# *
# * Following are the execution state flow of this build script
# *    1) Clone the android binder repositories from list ${REPOSITORIES}
# *       to the tag ${TAG}=android-13.0.0_r74
# *    2) The patches will be applied from ./patches/
# *    3) Call cmake to build the binder module for linux.
# *       This will also, build the aidl/aidl-cpp utility for host/linux to generate stubs and
# *       proxies form .aidl file. Following are the generated binaries and libraries
# *           liblog
# *           libbase
# *           libcutils_sockets
# *           libcutils
# *           libutils
# *           libbinder
# *           servicemanager
# *    4) The generated bins, libs and headers will be installed in ${INSTALL_DIR}.
# *

linux_binder_dir=$(dirname "$(realpath "$0")")
. ${linux_binder_dir}/setup-env.sh
if [ $? -ne 0 ]; then
    LOGE "Failed to export environments"
    exit 1
fi
LOGI "Successfully setup environments"

clone_android_binder_repo
if [ $? -ne 0 ]; then
    LOGE "Failed to clone android repos"
    exit 2
fi
LOGI "Successfully cloned android repos"

build_linux_binder
if [ $? -ne 0 ]; then
    LOGE "Failed to build binder for linux"
    exit 3
fi
LOGI "Successfully build binder for linux"
