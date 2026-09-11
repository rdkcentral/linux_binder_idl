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

# One SDK per rootfs in the ordinary case, so a single path is enough. A mixed
# rootfs cannot use a global one: LD_LIBRARY_PATH is searched BEFORE a binary's
# DT_RUNPATH, which is what modern linkers emit, so a global 64-bit path wins
# over a 32-bit binary's own rpath and it loads libraries of the wrong ELF
# class. Each process there is given its own path instead (see below).
export LD_LIBRARY_PATH=/opt/binder/lib

# A mixed-bitness rootfs carries a second SDK at /opt/binder32 and a second
# build of the test binary beside it. The scenario on the kernel command line
# says which build serves and which calls; without one this is an ordinary
# single-bitness guest and nothing below changes.
SCENARIO=""
for a in $(cat /proc/cmdline 2>/dev/null); do
    case "${a}" in binder_scenario=*) SCENARIO="${a#binder_scenario=}" ;; esac
done

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

case "${SCENARIO}" in
    "")
        # Single process, both ends: the original gate.
        /opt/binder/bin/binder_roundtrip
        ;;
    server64-client32|server32-client64)
        # Two processes of DIFFERENT ELF class transacting through one kernel.
        # The server registers and stays up; the client looks it up and calls
        # it, so the reply crosses the bitness boundary in both directions.
        case "${SCENARIO}" in
            server64-client32) SRV=/opt/binder   ; CLI=/opt/binder32 ;;
            server32-client64) SRV=/opt/binder32 ; CLI=/opt/binder   ;;
        esac
        LD_LIBRARY_PATH="${SRV}/lib" "${SRV}/bin/binder_roundtrip" --server "${SCENARIO}" >/server.log 2>&1 &
        # Wait for the server's own readiness line rather than sleeping blind,
        # and rather than retrying the client - a retry loop prints a FAIL
        # sentinel on every attempt before the one that works, which reads as a
        # failure that then mysteriously passes.
        i=0
        while [ "${i}" -lt 20 ]; do
            grep -q QEMU_BINDER_SERVER_READY /server.log 2>/dev/null && break
            i=$((i + 1))
            sleep 1
        done
        if ! grep -q QEMU_BINDER_SERVER_READY /server.log 2>/dev/null; then
            echo "QEMU_BINDER_RESULT: FAIL ${SCENARIO} server never registered"
            cat /server.log 2>/dev/null
        else
            LD_LIBRARY_PATH="${CLI}/lib" "${CLI}/bin/binder_roundtrip" --client "${SCENARIO}"
        fi
        ;;
    *)
        echo "QEMU_BINDER_RESULT: FAIL unknown binder_scenario=${SCENARIO}"
        ;;
esac

echo "QEMU_BINDER_DONE"

poweroff -f
