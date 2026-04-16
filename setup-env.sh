#!/usr/bin/env bash
#/**
# * Copyright 2024 Comcast Cable Communications Management, LLC
# *
# * Licensed under the Apache License, Version 2.0 (the "License");
# * you may not use this file except in compliance with the License.
# * You may obtain a copy of the License at
# *
# *     http://www.apache.org/licenses/LICENSE-2.0
# *
# * Unless required by applicable law or agreed to in writing, software
# * distributed under the License is distributed on an "AS IS" BASIS,
# * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# * See the License for the specific language governing permissions and
# * limitations under the License.
# *
# * SPDX-License-Identifier: Apache-2.0
# */

# ==============================================================================
# setup-env.sh
#
# Shared environment & helpers for all linux-binder-aidl scripts.
#
# Contains ONLY:
#   - Core paths (WORK_DIR, OUT_DIR, TARGET_SDK_DIR, HOST_AIDL_DIR, ...)
#   - Shared tool config (CMAKE, MAKE, GIT, TAR_BIN)
#   - Logging helpers (LOGI/LOGW/LOGE) and tiny FS helpers (CD/RM/MKDIR/...)
#
# Does NOT contain:
#   - TAG / REPOSITORIES
#   - clone_android_binder_repo()
#   - build_linux_binder()
#   - any script-specific logic
# ==============================================================================

set -e

#########################
# Core paths
#########################
WORK_DIR="${WORK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Single output root
OUT_DIR="${OUT_DIR:-${WORK_DIR}/out}"

# Target SDK (what target code links against)
TARGET_SDK_DIR="${TARGET_SDK_DIR:-${OUT_DIR}/target}"

# Host-side outputs
HOST_OUT_DIR="${HOST_OUT_DIR:-${OUT_DIR}/host}"
HOST_AIDL_DIR="${HOST_AIDL_DIR:-${HOST_OUT_DIR}/aidl_compiler}"

# Build trees
TARGET_BUILD_DIR="${TARGET_BUILD_DIR:-${OUT_DIR}/build/target}"
HOST_AIDL_BUILD_DIR="${HOST_AIDL_BUILD_DIR:-${OUT_DIR}/build/host_aidl}"

# Android sources root
ANDROID_DIR="${ANDROID_DIR:-${WORK_DIR}/android}"

#########################
# Tools and command wrappers
#########################
CMAKE="${CMAKE:-cmake}"
MAKE="${MAKE:-make}"
GIT="${GIT:-git}"
TAR_BIN="${TAR_BIN:-tar}"

CD="cd"
RM="rm -rf"
MKDIR="mkdir -p"
PUSHD="pushd"
POPD="popd"

#########################
# Colours & logging
#########################
RED="\033[1;31m"
YEL="\033[1;33m"
GRN="\033[1;32m"
GREEN="\033[1;32m"
CYAN="\033[1;36m"
NC="\033[0m"

LOGI() { echo -e "${GRN}[INFO]${NC}  $*"; }
LOGW() { echo -e "${YEL}[WARN]${NC}  $*"; }
LOGE() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
