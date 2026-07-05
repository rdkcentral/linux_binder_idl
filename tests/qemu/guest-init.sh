#!/bin/sh
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
# PID 1 inside the QEMU guest. Mounts the pseudo-filesystems, provisions the
# binder device for this kernel, starts servicemanager, runs the binder
# round-trip, prints its sentinel, then powers off so QEMU exits.
set -u

mount -t proc     proc     /proc      2>/dev/null
mount -t sysfs    sysfs    /sys       2>/dev/null
mount -t devtmpfs devtmpfs /dev       2>/dev/null

export LD_LIBRARY_PATH=/opt/binder/lib

# Provision /dev/binder. Kernels >= 5.0 expose binderfs; create the device
# there. Older kernels rely on the static node from CONFIG_ANDROID_BINDER_DEVICES.
if [ ! -e /dev/binder ]; then
    if mkdir -p /dev/binderfs && mount -t binder binder /dev/binderfs 2>/dev/null; then
        echo binder > /dev/binderfs/binder-control 2>/dev/null
        [ -e /dev/binderfs/binder ] && ln -sf /dev/binderfs/binder /dev/binder
    fi
fi
if [ ! -e /dev/binder ]; then
    echo "QEMU_BINDER_RESULT: FAIL no /dev/binder on kernel $(uname -r)"
    poweroff -f
    exit 1            # deterministic stop if poweroff is delayed/fails
fi

# servicemanager must own the context before the test calls defaultServiceManager().
# It has no readiness file to poll, so give it a brief moment to register as the
# context manager (BINDER_SET_CONTEXT_MGR) before the test connects.
/opt/binder/bin/servicemanager >/dev/null 2>&1 &
sleep 2

echo "QEMU_BINDER_KERNEL: $(uname -r)"
/opt/binder/bin/binder_roundtrip
echo "QEMU_BINDER_DONE"

poweroff -f
