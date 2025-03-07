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
 * FirmwareStatus.aidl
 *
 * The parcelable contains the following Firmware status information.
 * state:
 *     A string containing the state of the OS firmware update component.
 * percentProgress:
 *     Represents the total progress through the check/download/verify an install flow.
 * compulsory:
 *     Used to specify the firmware detected is mandatory or not.
 */

// FirmwareStatus.aidl
package com.test;

parcelable FirmwareStatus {
    String state;
    int percentProgress;
    boolean compulsory;
}
