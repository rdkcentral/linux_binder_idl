#!/bin/sh

linux_binder_dir=$(dirname "$(realpath "$0")")
. ${linux_binder_dir}/setup-env.sh
if [ $? -ne 0 ]; then
    LOGE "Failed to export environments"
    exit 1
fi
LOGI "Successfully setup environments"

clone_android_binder_repo
if [ $? -ne 0 ]; then
    LOGE "Failed to clone android repos"
    exit 2
fi
LOGI "Successfully cloned android repos"
