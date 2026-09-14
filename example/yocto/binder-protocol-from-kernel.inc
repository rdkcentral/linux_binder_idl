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
# OPTIONAL - derive the binder wire protocol from the kernel instead of stating
# it. Use it from a recipe with:
#
#     require binder-protocol-from-kernel.inc
#     EXTRA_OECMAKE += " -DBINDER_PROTOCOL=${BINDER_PROTOCOL_RESOLVED}"
#
# WHEN YOU WANT THIS. Every supported platform is protocol 8, so a recipe can
# simply say so - which is what linux-binder.bb does, and it is the simpler
# thing. This is for a fleet that still has protocol-7 platforms in it, where
# one recipe has to serve both: it reads what each kernel actually serves rather
# than carrying a per-platform override that can go stale.
#
# What it buys even on an all-protocol-8 fleet is a guard. A kernel drifting back
# to protocol 7 - someone re-adding the Kconfig patch, say - becomes a BUILD
# failure here, instead of a device where every binder process dies at startup.
#
# BINDER_PROTOCOL declares the protocol for a build with no kernel in scope, an
# SDK for instance. Given both, they must agree.

BINDER_PROTOCOL ?= ""

# The protocol comes from the kernel, so the recipe needs the configured kernel
# in scope to read it.
do_configure[depends] += "virtual/kernel:do_shared_workdir"

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

BINDER_PROTOCOL_RESOLVED ?= "${@binder_protocol(d)}"
BINDER_PROTOCOL_SOURCE   ?= "${@binder_protocol_source(d)}"
