/*
 * Copyright 2026 RDK Management
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

// Minimal Binder round-trip, run inside the QEMU guest against the booted
// kernel's binder driver. It proves the shipped libbinder runtime comes up and
// completes a transaction on this kernel version:
//
//   1. ProcessState::self() opens /dev/binder and runs libbinder's strict
//      BINDER_VERSION check — this alone catches a kernel/userspace protocol
//      mismatch (the 7-vs-8 trap), which is the #1 porting failure mode.
//   2. register a test service with servicemanager (must already be running),
//   3. fetch it back (a proxy routed through the kernel), and
//   4. transact: send 41, expect 42 — exercising Parcel marshal -> kernel ->
//      unmarshal -> onTransact -> reply, end to end.
//
// Emits a single sentinel line the host runner greps for:
//   QEMU_BINDER_RESULT: PASS ...   (exit 0)
//   QEMU_BINDER_RESULT: FAIL ...   (exit 1)

#include <binder/Binder.h>
#include <binder/IPCThreadState.h>
#include <binder/IServiceManager.h>
#include <binder/Parcel.h>
#include <binder/ProcessState.h>
#include <utils/String16.h>
#include <utils/StrongPointer.h>

#include <cstdio>

using namespace android;

static const uint32_t TEST_CODE = IBinder::FIRST_CALL_TRANSACTION + 1;
static const char* kServiceName = "rdk.binder.roundtrip.test";

namespace {

void pass(const char* detail) { printf("QEMU_BINDER_RESULT: PASS %s\n", detail); fflush(stdout); }
int  fail(const char* detail) { printf("QEMU_BINDER_RESULT: FAIL %s\n", detail); fflush(stdout); return 1; }

// Hosted in this process; servicemanager hands callers a proxy back to it.
class TestService : public BBinder {
public:
    status_t onTransact(uint32_t code, const Parcel& data, Parcel* reply, uint32_t flags) override {
        if (code == TEST_CODE) {
            reply->writeInt32(data.readInt32() + 1);   // echo + 1
            return OK;
        }
        return BBinder::onTransact(code, data, reply, flags);
    }
};

}  // namespace

int main() {
    // 1. Driver open + protocol-version check happens here.
    sp<ProcessState> proc = ProcessState::self();
    proc->startThreadPool();

    sp<IServiceManager> sm = defaultServiceManager();
    if (sm == nullptr) return fail("no servicemanager (is it running?)");

    // 2. register
    sp<TestService> svc = new TestService();
    if (sm->addService(String16(kServiceName), svc) != OK) return fail("addService failed");

    // 3. fetch (non-blocking: checkService, so a misconfigured guest can't hang)
    sp<IBinder> handle = sm->checkService(String16(kServiceName));
    if (handle == nullptr) return fail("checkService returned null");

    // 4. round-trip transaction
    Parcel data, reply;
    data.writeInt32(41);
    status_t st = handle->transact(TEST_CODE, data, &reply);
    if (st != OK) return fail("transact returned non-OK");
    int32_t got = reply.readInt32();
    if (got != 42) return fail("unexpected reply value");

    pass("(servicemanager round-trip 41->42)");

    // ---- HALIF interface hook -------------------------------------------------
    // To exercise a generated HALIF interface end to end, link a snapshot's
    // lib<module>-v<ver>-cpp.so, then here:
    //   sp<Bn<Iface>> impl = new <VendorImpl>();
    //   sm->addService(String16("<iface-name>"), impl);
    //   sp<I<Iface>> p = I<Iface>::asInterface(sm->checkService(String16("<iface-name>")));
    //   ... call a method and assert the result ...
    // See tests/qemu/README.md.
    // ---------------------------------------------------------------------------

    return 0;
}
