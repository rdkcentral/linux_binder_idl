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
 * BinderDevice.c
 *
 * linux binder-device tool to create binder node if it is not exists in the
 * machine (mainly in Ubuntu). Run below commands to create binder device node
 *     # ./binder-device /dev/binderfs/binder-control /dev/binderfs/binder
 *     # chmod 0755 /dev/binderfs/binder
 *     # ln -sf /dev/binderfs/binder /dev/binder
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <linux/android/binder.h>
#include <linux/android/binderfs.h>


void Help(char *binderDeviceExe) {
    printf("\nUsage : \n");
    printf("%s [binder-control path] [binder name]\n", binderDeviceExe);
    printf("\nExample :\n");
    printf("$ %s /dev/binderfs/binder-control /dev/binder\n", binderDeviceExe);
}

int main(int argc, char *argv[])
{
    int fileDesc;
    size_t length;
    struct binderfs_device device = { 0 };
    int ret = 0;

    if (argc != 3) {
        printf("Invalid arguments.\n");
        Help(argv[0]);
        return 1;
    }

    length = strlen(argv[2]);
    if (length > BINDERFS_MAX_NAME) {
        printf("Invalid binderfs name length [%ld]\n", length);
        return 2;
    }

    memcpy(device.name, argv[2], length);

    fileDesc = open(argv[1], O_RDONLY | O_CLOEXEC);
    if (fileDesc < 0) {
        printf("Failed to open binder-control device\n");
        printf("Error message : [%s]\n", strerror(errno));
        return 3;
    }

    ret = ioctl(fileDesc, BINDER_CTL_ADD, &device);
    if (ret < 0) {
        printf("Failed to allocate new binder device\n");
        printf("Error message : [%s]\n", strerror(errno));
        close(fileDesc);
        return 4;
    }

    close(fileDesc);

    printf("Successfully allocated new binder device\n");
    printf("Major [%d], Minor [%d], and Name [%s]\n", device.major, device.minor, device.name);

    return ret;
}
