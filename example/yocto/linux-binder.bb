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

# Escape hatch for a build with no kernel in scope, an SDK for instance. Left
# empty the protocol is derived, which is what a device build should do.
BINDER_PROTOCOL ?= ""

def binder_protocol(d):
    """Return the wire protocol this build must speak: '7' or '8'."""
    import os
    want = d.getVar('BINDER_PROTOCOL') or ''
    cfg = os.path.join(d.getVar('STAGING_KERNEL_BUILDDIR') or '', '.config')
    derived = ''
    if os.path.exists(cfg):
        # Read the RESOLVED .config, never the defconfig. A defconfig may
        # request a symbol the kernel's Kconfig no longer has, and the request
        # is dropped silently - so a defconfig can claim protocol 7 while the
        # kernel it produced serves protocol 8.
        derived = '8'
        with open(cfg) as f:
            for line in f:
                if line.strip() == 'CONFIG_ANDROID_BINDER_IPC_32BIT=y':
                    derived = '7'
                    break
    if derived and want and derived != want:
        bb.fatal("binder: the kernel serves protocol %s but BINDER_PROTOCOL is "
                 "%s. A mismatch terminates every binder process at startup."
                 % (derived, want))
    proto = derived or want
    if not proto:
        bb.fatal("binder: no kernel .config in scope and BINDER_PROTOCOL is "
                 "unset, so the wire protocol cannot be determined.")
    if proto not in ('7', '8'):
        # Anything else is a typo. Mapping it to a protocol silently is how a
        # configuration mistake becomes a device that will not boot.
        bb.fatal("binder: BINDER_PROTOCOL is '%s'; the only wire protocols are "
                 "7 and 8." % proto)
    return proto

def binder_protocol_source(d):
    """Where that answer came from, for the build log."""
    import os
    cfg = os.path.join(d.getVar('STAGING_KERNEL_BUILDDIR') or '', '.config')
    return "kernel:%s" % cfg if os.path.exists(cfg) else "declared:BINDER_PROTOCOL"

# Three switches, all stated rather than inherited.
#
#   BUILD_HOST_AIDL   always OFF - the host AIDL tool is not part of an image.
#   TARGET_LIB*       the ELF class, which follows the TOOLCHAIN. SITEINFO_BITS
#                     reports 32 for a lib32- multilib variant and 64 for the
#                     base recipe, so both roles build from one expression.
#   BINDER_IPC_32BIT  the wire protocol, which follows the KERNEL. Protocol 8 is
#                     the default; deriving it anyway turns a platform drifting
#                     back to protocol 7 into a build failure rather than a boot
#                     failure.
# Resolved once, and readable without running a task:
#     bitbake -e linux-binder | grep ^BINDER_PROTOCOL_RESOLVED
# The switch derives from it, so the decision has exactly one evaluation point.
BINDER_PROTOCOL_RESOLVED ?= "${@binder_protocol(d)}"
BINDER_PROTOCOL_SOURCE   ?= "${@binder_protocol_source(d)}"

EXTRA_OECMAKE += " \
    -DBUILD_HOST_AIDL=OFF \
    -DBINDER_IPC_32BIT=${@'ON' if d.getVar('BINDER_PROTOCOL_RESOLVED') == '7' else 'OFF'} \
    ${@bb.utils.contains('SITEINFO_BITS', '32', '-DTARGET_LIB32_VERSION=ON', '-DTARGET_LIB64_VERSION=ON', d)} \
"

# State the decision once, in the task log, in a form a test can grep. CMake
# prints its own "binder wire protocol: N" line, so the two are independent
# statements of the same fact and a disagreement is visible.
do_configure:prepend() {
    bbplain "binder: protocol=${BINDER_PROTOCOL_RESOLVED} bits=${SITEINFO_BITS} source=${BINDER_PROTOCOL_SOURCE}"
}

do_install:append() {
    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${WORKDIR}/servicemanager.service ${D}${systemd_unitdir}/system
}

SYSTEMD_SERVICE:${PN} = "servicemanager.service"
SYSTEMD_AUTO_ENABLE = "enable"

FILES:${PN} += "${libdir}/lib*.so*"
FILES:${PN}-dev += "${includedir}/*"
