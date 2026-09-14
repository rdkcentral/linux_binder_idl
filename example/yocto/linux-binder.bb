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
# It builds the target runtime libraries only. The AIDL compiler is a host tool
# the architecture team runs offline, and no target image carries it.

SUMMARY = "Linux Binder IPC runtime (libbinder, libutils, servicemanager)"
LICENSE = "Apache-2.0"

# files/ sits beside this recipe and holds the systemd unit. Without this a
# layer that copies only the .bb fails during fetch, before anything builds.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "${RDKCENTRAL_GITHUB_ROOT}/linux_binder_idl;${RDKCENTRAL_GITHUB_SRC_URI_SUFFIX}"
SRC_URI += "file://servicemanager.service"

# Pin to a released tag. A branch name or a feature-branch SHA makes the build
# unreproducible and is not a supported configuration.
PV ?= "2.6.0"
SRCREV ?= "2.6.0"
S = "${WORKDIR}/git"

# libbinder provides liblog; do not also build liblog.bb.
RPROVIDES:${PN}:append = " liblog"
PROVIDES:append = " liblog"

inherit cmake systemd siteinfo

# The wire protocol belongs to the kernel, so the recipe needs the configured
# kernel in scope to read it.
do_configure[depends] += "virtual/kernel:do_shared_workdir"

# Protocol 8, on every platform. It is what every 64-bit kernel serves, what
# every kernel from 4.18 serves, and what a 32-bit userspace runs perfectly well
# - it needs 64-bit FIELDS, not a 64-bit anything. Protocol 7 is legacy
# compatibility and is being retired.
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

do_install:append() {
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
