#/**
# * Copyright 2026 RDK Management
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
#
# REFERENCE RECIPE - build the Binder SDK for a target image.
#
# Copy this into your own layer and adapt it. It is the recipe BUILD.md
# documents, kept here as a file so the guidance is something you can diff
# against rather than retype; tests/test_yocto_recipe_example.sh fails if the
# two disagree or if a required switch goes missing.
#
# It builds the target runtime libraries only. The AIDL compiler is a build-host
# tool, and no target image carries it.

SUMMARY = "Linux Binder IPC runtime (libbinder, libutils, servicemanager)"
LICENSE = "Apache-2.0"
# A non-CLOSED licence needs a checksum, or do_populate_lic fails before the
# build starts. Points at the LICENSE file in the fetched source.
LIC_FILES_CHKSUM = "file://LICENSE;md5=175792518e4ac015ab6696d16c4f607e"

# files/ sits beside this recipe and holds the systemd unit. Without this a
# layer that copies only the .bb fails during fetch, before anything builds.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "${RDKCENTRAL_GITHUB_ROOT}/linux_binder_idl;${RDKCENTRAL_GITHUB_SRC_URI_SUFFIX}"
SRC_URI += "file://servicemanager.service"

# Pin to a released tag. A branch name or a feature-branch SHA makes the build
# unreproducible and is not a supported configuration. The switches below need
# 2.7.0 or later.
PV ?= "2.7.0"
SRCREV ?= "2.7.0"
S = "${WORKDIR}/git"

# AOSP sources: one tarball, defined by aosp/manifest in the SDK source and
# identified by the sha256 below.
#
# AOSP_SOURCE_URI IS A PLACEHOLDER. The SDK publishes no tarball, and
# artifacts.example.invalid does not exist. Before this recipe can fetch:
#   1. run ./aosp-source.sh generate in a checkout of the SRCREV above;
#   2. upload downloads/${AOSP_SOURCE_NAME} to your team's artifact store
#      (e.g. Artifactory);
#   3. set AOSP_SOURCE_URI to its URL in your layer, or map the placeholder
#      through PREMIRRORS.
# The sha256 is the same wherever the tarball is hosted. For another SRCREV,
# ./aosp-source.sh name and ./aosp-source.sh sha256 print both values.
AOSP_SOURCE_NAME = "aosp-android-13.0.0_r74-src-5cdb5cab.tar.gz"
AOSP_SOURCE_URI ?= "https://artifacts.example.invalid/linux-binder/${AOSP_SOURCE_NAME}"
SRC_URI += "${AOSP_SOURCE_URI};name=aosp;subdir=git;downloadfilename=${AOSP_SOURCE_NAME}"
SRC_URI[aosp.sha256sum] = "40949243453e9cf3b66fbaa300ff2de5d63d9feac874230bb1f9245959f2b88c"

# libbinder provides liblog; do not also build liblog.bb.
RPROVIDES:${PN}:append = " liblog"
PROVIDES:append = " liblog"

inherit cmake systemd siteinfo

# No kernel dependency: this recipe STATES protocol 8 rather than reading it, so
# it never opens the kernel's .config and has no reason to wait for one. The
# dependency belongs with the derivation - binder-protocol-from-kernel.inc adds
# it, and only when it is actually deriving. Declaring it here would pull a
# kernel into the build for nothing, and fail outright where no kernel provider
# exists at all, such as an SDK build.

# Protocol 8, on every platform. It is what every 64-bit kernel serves, what
# every kernel from 4.18 serves, and what a 32-bit userspace runs perfectly well
# - it needs 64-bit FIELDS, not a 64-bit anything. Protocol 7 is legacy
# compatibility, for a 32-bit kernel at 4.17 or older that still carries
# CONFIG_ANDROID_BINDER_IPC_32BIT.
#
# The ELF class is NOT passed. It follows CC/CXX, which the toolchain already
# sets, and nothing in the build can change it - so declaring it would only
# restate what the compiler already says. Add -DTARGET_BITNESS=${SITEINFO_BITS}
# if you want the build to STOP when the toolchain is not the bitness this
# recipe is being built for; it is an assertion, not a setting.
#
# If your fleet still has protocol-7 platforms, or you want a kernel drifting
# back to protocol 7 to fail the BUILD rather than the device, derive it instead:
#
#     require binder-protocol-from-kernel.inc
#     EXTRA_OECMAKE += " -DBINDER_PROTOCOL=${BINDER_PROTOCOL_RESOLVED}"
#
EXTRA_OECMAKE += " \
    -DBUILD_HOST_AIDL=OFF \
    -DBINDER_PROTOCOL=8 \
"

# CMake installs the runtime - libraries, headers and servicemanager - with the
# RUNPATH set for the install prefix. It skips those install rules when it finds
# an SDK environment (OECORE_NATIVE_SYSROOT or OECORE_TARGET_SYSROOT). A BitBake
# task does not set them, but a devtool or eSDK shell can carry them in, so they
# are cleared before configure, and do_install stops if the runtime is missing
# from ${D} rather than packaging an empty one.
do_configure:prepend() {
    unset OECORE_NATIVE_SYSROOT OECORE_TARGET_SYSROOT
}

# The tarball holds unpatched upstream. The SDK's patches/ is applied on top by
# the same script a standalone build uses, so both build the same source.
do_patch[postfuncs] += "linux_binder_aosp_patches"
linux_binder_aosp_patches() {
    ${S}/aosp-source.sh apply-patches --android-dir ${S}/android
}

do_install:append() {
    for f in ${libdir}/libbinder.so ${bindir}/servicemanager ${includedir}/binder/IBinder.h; do
        [ -e "${D}$f" ] || bbfatal "CMake did not install $f - the target runtime is incomplete"
    done

    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${WORKDIR}/servicemanager.service ${D}${systemd_unitdir}/system
}

SYSTEMD_SERVICE:${PN} = "servicemanager.service"
SYSTEMD_AUTO_ENABLE = "enable"

# These libraries are UNVERSIONED - the SDK ships a plain libbinder.so, with no
# SONAME and no libbinder.so.1 beside it. That matters for packaging: OE's
# default -dev FILES claim ${libdir}/lib*.so, and -dev is ordered BEFORE ${PN}
# in PACKAGES, so -dev takes the real objects and do_package_qa rejects them:
#
#   QA Issue: -dev package libbinder-dev contains non-symlink .so
#             '/usr/lib/libbinder.so' [dev-elf]
#
# So -dev is ASSIGNED rather than appended, dropping the default .so glob. The
# runtime package keeps the libraries, which is correct - unversioned, they are
# the runtime artifact, not a development symlink. Consumers still link against
# them because do_populate_sysroot stages from ${D}, not from the -dev package.
FILES:${PN} += "${libdir}/lib*.so*"
FILES:${PN}-dev = "${includedir}/*"
