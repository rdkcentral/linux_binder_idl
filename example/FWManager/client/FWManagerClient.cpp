/**
 * Copyright 2024 Comcast Cable Communications Management, LLC
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

/** @brief
 * FWManagerClient.cpp
 *
 * The FWManager client code that calls the interfaces and callbacks provided by
 * the FWManager service.
 */

#include <sysexits.h>
#include <unistd.h>
#include <sys/reboot.h>

#include <string>
#include <vector>

#include <iostream>
#include <fstream>

#include <binder/IServiceManager.h>
#include <utils/String16.h>
#include <utils/StrongPointer.h>
#include <cutils/properties.h>

#include "com/test/FirmwareStatus.h"
#include "com/test/BnFirmwareUpdateStateListener.h"
#include "com/test/IFWManager.h"

#include <binder/IPCThreadState.h>
#include <binder/ProcessState.h>

using android::OK;
using android::String16;
using android::String8;
using android::sp;

using android::binder::Status;

using namespace com::test;
using namespace android;
using namespace std;

#define FW_MGR_TEST_APP_VERSION        "1.0.0"

int main() {

    printf("\n\n");
    printf("###########################################################\n");
    printf("FWManager Test App - V%s %s\n", __TIMESTAMP__);
    printf("###########################################################\n");
    printf("\n\n");

    sp<IFWManager> fwManagerService;
    status_t status;

    printf("\nFWManagerTestApp : Getting FWManagerService from ServiceManager\n");
    status = getService(String16("FWManagerService"), &fwManagerService);
    if (status != OK) {
        printf("\nFWManagerTestApp : Failed to Get FWManagerService handle from ServiceManager : [%s]\n", Status::fromStatusT(status).toString8().c_str());
        return -1;
    }

    FirmwareStatus fwStatus;
    Status binderStatus;
    binderStatus = fwManagerService->getFirmwareUpdateState(&fwStatus);
    if (!binderStatus.isOk()) {
        printf("\nFWManagerTestApp : Failed getFirmwareUpdateState\n");
        return -2;
    }

    printf("\n===================================\n");
    printf("State : [%s]\n", String8{fwStatus.state}.string());
    printf("Percent Progress : [%d]\n", fwStatus.percentProgress);
    printf("Compulsory Flag : [%d]\n", fwStatus.compulsory);
    printf("\n===================================\n");

    class FWManagerListener : public BnFirmwareUpdateStateListener {
        public:

            FWManagerListener() {};
            virtual ~FWManagerListener() = default;

            // com::test::BnFirmwareUpdateStateListener overrides.
            Status onFirmwareUpdateStateChanged(const FirmwareStatus& fwStatus) override {

                printf("\n===================================\n");
                printf("State : [%s]\n", String8{fwStatus.state}.string());
                printf("Percent Progress : [%d]\n", fwStatus.percentProgress);
                printf("Compulsory Flag : [%d]\n", fwStatus.compulsory);
                printf("\n===================================\n");

                return Status::ok();
            }
    };

    sp<IFirmwareUpdateStateListener> listener;

    printf("\nFWManagerTestApp : Register FirmwareUpdateStateListener\n");
    listener = new FWManagerListener();

    binderStatus = fwManagerService->registerDeviceStateFirmwareUpdateStateChanged(listener);
    if (!binderStatus.isOk()) {
        printf("Register Student Callback Failed\n");
        return -2;
    }
    printf("\nFWManagerTestApp :  Register FirmwareUpdateStateListener Success\n");

    // Keep the main thread alive to receive callbacks
    ProcessState::self()->startThreadPool();
    IPCThreadState::self()->joinThreadPool();

    printf("\nFWManagerTestApp :  Receiving Callbacks...\n");

    return 0;
}
