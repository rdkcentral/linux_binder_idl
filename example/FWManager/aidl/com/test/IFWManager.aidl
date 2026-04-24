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
 * IFWManager.aidl
 *
 * Contains the Firmware Manager service interfaces.
 */

// IFWManager.aidl
package com.test;

import android.os.ParcelFileDescriptor;
import com.test.FirmwareStatus;
import com.test.IFirmwareUpdateStateListener;

interface IFWManager {

    /*
     * Gets the active firmware version.
     */
    String getFirmwareVersion() = 400;

    /*
     * Gets the current active firmware bank.
     */
    int getCurrentBootBank() = 401;

    /*
     * Triggers an immediate check for a new firmware version
     */
    boolean triggerFirmwareUpdateCheck() = 402;

    /*
     * Gets the current state of the OS firmware update component.
     */
    FirmwareStatus getFirmwareUpdateState() = 403;

    /*
     * Registers a listener for firmware update state changes.
     */
    void registerDeviceStateFirmwareUpdateStateChanged(in IFirmwareUpdateStateListener listener) = 404;

    /*
     * Gets a file descriptor for reading the firmware update log.
     * Demonstrates ParcelFileDescriptor as a built-in AIDL type.
     */
    ParcelFileDescriptor getFirmwareLogFile() = 405;
}
