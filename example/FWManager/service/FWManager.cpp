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
 * FWManager.cpp
 *
 * Contains the implementation of the FWManager interfaces.
 */

#include <string>
#include <iostream>
#include <fstream>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/reboot.h>

#include <android-base/unique_fd.h>

#include <binder/IServiceManager.h>
#include <utils/StrongPointer.h>

#include "FWManager.h"


using namespace std;
using namespace com::test;

void startFirmwareUpdatethread(const sp<IFirmwareUpdateStateListener>& listener);

/*
 * Gets the active firmware version.
 */
Status FWManager::getFirmwareVersion(String16* firmwareVersion) {
    char fwVersion[] = "STB_V_1.0.0";

    printf("\nFWManager : Current Firmware Version : [%s]\n", fwVersion);
    *firmwareVersion = String16{fwVersion};

    return Status::ok();
}

/*
 * Gets the current active firmware.
 */
Status FWManager::getCurrentBootBank(int* currentBootBank) {
    *currentBootBank = 4;
    printf("\nFWManager : Booted from Slot A [%d]\n", *currentBootBank);

    return Status::ok();
}

/*
 * Triggers an immediate check for a new firmware version
 */
Status FWManager::triggerFirmwareUpdateCheck(bool* updateCheck) {
    bool isTriggered = true;

    printf("\nFWManager : Trigger FW Upgrade...\n");
    printf("\nFWManager : Starting initiateSWUpdate Service. Triggered = [%d]\n", isTriggered);

    *updateCheck = isTriggered;

    return Status::ok();
}

/*
 * Gets the current state of the OS firmware update component.
 */
Status FWManager::getFirmwareUpdateState(FirmwareStatus* firmwareStatus) {
    char fwState[] = "DOWNLOADING";
    int percentProgress = 55;
    bool compulsory = true;

    firmwareStatus->state = String16{fwState};
    firmwareStatus->percentProgress = percentProgress;
    firmwareStatus->compulsory = compulsory;

    printf("\nFWManager : Firmware Update Status : State [%s] Percent [%d] Compulsory [%d]\n",
         String8{firmwareStatus->state}.string(), firmwareStatus->percentProgress,
         firmwareStatus->compulsory);

    return Status::ok();
}

/*
 * Registers a listener for firmware update state changes.
 */
Status FWManager::registerDeviceStateFirmwareUpdateStateChanged(const sp<IFirmwareUpdateStateListener>& listener) {
    printf("\nFWManager : Register IFirmwareUpdateStateListener\n");
    std::thread threadStartFirmwareUpdate(startFirmwareUpdatethread, listener);
    threadStartFirmwareUpdate.detach();

    return Status::ok();
}

/*
 * Gets a file descriptor for reading the firmware update log.
 * Opens /tmp/fw_update.log (or creates it) and returns the fd to the caller.
 */
Status FWManager::getFirmwareLogFile(::android::os::ParcelFileDescriptor* _aidl_return) {
    const char* logPath = "/tmp/fw_update.log";

    int fd = open(logPath, O_RDONLY | O_CREAT, 0644);
    if (fd < 0) {
        printf("\nFWManager : Failed to open firmware log file: %s\n", logPath);
        return Status::fromServiceSpecificError(-1, String8("Failed to open log file"));
    }

    printf("\nFWManager : Returning firmware log fd=%d for %s\n", fd, logPath);
    _aidl_return->reset(android::base::unique_fd(fd));

    return Status::ok();
}

void startFirmwareUpdatethread(const sp<IFirmwareUpdateStateListener>& listener) {
    int i = 0;
    FirmwareStatus firmwareStatus;
    string fwStates [] = {"IDLE", "AVAILABLE", "DOWNLOADING", "DOWNLOADING", "DOWNLOADING", "DOWNLOADING", "VERIFYING",
                          "VERIFYING", "VERIFYING", "INSTALLING", "INSTALLING", "INSTALLING", "INSTALLED", "REBOOTING"};
    int percentProgresses [] = { 0, 0, 13, 24, 36, 50, 55, 60, 65, 72, 85, 99, 100, 100};
    bool compulsoryFlags [] = {true, false, false, true, false, false, false, true, true, true, true, true, true, true};

    printf("\nFWManager : Start Firmware Update Thread\n");

    while(1) {

        firmwareStatus.state = String16{fwStates[i].c_str()};
        firmwareStatus.percentProgress = percentProgresses[i];
        firmwareStatus.compulsory = compulsoryFlags[i];

        printf("\n\n\nFWManager : Firmware Update State [%s] Percent [%d] Compulsory [%d]\n\n\n",
                String8{firmwareStatus.state}.string(), firmwareStatus.percentProgress,
                firmwareStatus.compulsory);
        listener->onFirmwareUpdateStateChanged(firmwareStatus);

        i++;
        if (i == 14) {
            break;
        }

        sleep(2);
    }

    printf("\nFWManager : Exiting FW Update Start Thread\n");
}
