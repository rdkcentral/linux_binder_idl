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
 * FWManager.h
 *
 * The header file contains the FWManager service interfaces.
 */

#ifndef _FW_MANAGER_H_
#define _FW_MANAGER_H_

#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

#include <android/log.h>
#include <binder/BinderService.h>
#include <binder/ParcelFileDescriptor.h>
#include <binder/Status.h>
#include <utils/Errors.h>
#include <utils/Log.h>

#include <utils/String16.h>
#include <utils/Vector.h>

#include "com/test/BnFWManager.h"
#include "com/test/IFirmwareUpdateStateListener.h"

// libutils
using android::OK;
using android::String8;
using android::String16;
using android::sp;

// libbinder
using android::defaultServiceManager;
using android::binder::Status;

// Generated code
using com::test::BnFWManager;
using com::test::FirmwareStatus;

// Standard library
using std::string;
using std::unique_ptr;
using std::vector;
using std::mutex;

using namespace com::test;

class FWManager : public android::BinderService<FWManager>,
                  public BnFWManager {
    private:
        friend class BinderService<FWManager>;

        FWManager() {}
        virtual ~FWManager() = default;

        static char const* getServiceName() { return "FWManagerService"; }

        /*
         * Gets the active firmware version.
         */
        Status getFirmwareVersion(String16* firmwareVersion) override;

        /*
         * Gets the current active firmware bank.
         */
        Status getCurrentBootBank(int* bootBank) override;

        /*
         * Triggers an immediate check for a new firmware version
         */
        Status triggerFirmwareUpdateCheck(bool* updateCheck) override;

        /*
         * Gets the current state of the OS firmware update component.
         */
        Status getFirmwareUpdateState(FirmwareStatus* fwStatus) override;

        /*
         * Registers a listener for firmware update state changes.
         */
        Status registerDeviceStateFirmwareUpdateStateChanged(const sp<IFirmwareUpdateStateListener>& listener) override;

        /*
         * Gets a file descriptor for reading the firmware update log.
         */
        Status getFirmwareLogFile(::android::os::ParcelFileDescriptor* _aidl_return) override;
};

#endif //_FW_MANAGER_H_
