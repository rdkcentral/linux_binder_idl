#/**
# * Copyright 2024 Comcast Cable Communications Management, LLC
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

# ** @brief : Build FWManager binder example module
# *           The cmake is used to build the FWManagerService and FWManagerClient module.
# *

###########################################################
# FWManager binder example
###########################################################

set(FWMANAGER_SERVICE_DIR ${FWMANAGER_DIR}/service)
set(FWMANAGER_CLIENT_DIR ${FWMANAGER_DIR}/client)
# Generated files are in stable/generated/FWManager/
set(FWMANAGER_GEN_DIR ${CMAKE_SOURCE_DIR}/stable/generated/FWManager)

###########################################################
# FWManager Service
###########################################################
set(FWMANAGER_SRCS
    ${FWMANAGER_SERVICE_DIR}/FWManager.cpp
)

if (USE_PREBUILT_GEN_FILES)
    message("Using generated prebuilt stubs and proxies")

    set(FWMANAGER_AIDL_SRCS
        ${FWMANAGER_GEN_DIR}/com/test/IFWManager.cpp
        ${FWMANAGER_GEN_DIR}/com/test/IFirmwareUpdateStateListener.cpp
        ${FWMANAGER_GEN_DIR}/com/test/FirmwareStatus.cpp
    )

    add_library(fwmanager SHARED
        ${FWMANAGER_SRCS}
        ${FWMANAGER_AIDL_SRCS}
    )

    target_include_directories(fwmanager PRIVATE
        ${FWMANAGER_GEN_DIR}/include
    )
else ()
    message("Generate stubs and proxies from .aidl file using aidl utility")

    set(FWMANAGER_AIDL_SRCS
        "com/test/IFWManager.aidl"
        "com/test/IFirmwareUpdateStateListener.aidl"
        "com/test/FirmwareStatus.aidl"
    )

    AidlGenerator(FWMANAGER_AIDL "${FWMANAGER_DIR}/aidl" "${FWMANAGER_AIDL_SRCS}")

    add_library(fwmanager SHARED
        ${FWMANAGER_SRCS}
        ${FWMANAGER_AIDL_OUTPUTS}
    )

    target_include_directories(fwmanager PRIVATE
        ${GENERATED_DIR}/FWMANAGER_AIDL/include
    )
endif ()

target_compile_options(fwmanager PRIVATE
    -Wall -Wextra -std=c++17
)

target_include_directories(fwmanager PRIVATE
    ${FWMANAGER_SERVICE_DIR}/service
)

target_link_libraries(fwmanager PRIVATE binder utils)

# FWManagerService
add_executable(FWManagerService ${FWMANAGER_SERVICE_DIR}/FWManagerService.cpp)

target_compile_options(FWManagerService PRIVATE
    -Wall -Wextra -std=c++17
)

if (USE_PREBUILT_GEN_FILES)
    target_include_directories(FWManagerService PRIVATE
        ${FWMANAGER_GEN_DIR}/include
    )
else ()
    target_include_directories(FWManagerService PRIVATE
        ${GENERATED_DIR}/FWMANAGER_AIDL/include
    )
endif ()

target_link_libraries(FWManagerService PRIVATE binder utils fwmanager)

###########################################################
# FWManager Client
###########################################################
if (USE_PREBUILT_GEN_FILES)
    add_executable(FWManagerClient
        ${FWMANAGER_CLIENT_DIR}/FWManagerClient.cpp
        ${FWMANAGER_AIDL_SRCS})

    target_include_directories(FWManagerClient PRIVATE
        ${FWMANAGER_GEN_DIR}/include
    )
else ()
    add_executable(FWManagerClient
        ${FWMANAGER_CLIENT_DIR}/FWManagerClient.cpp
        ${FWMANAGER_AIDL_OUTPUTS})

    target_include_directories(FWManagerClient PRIVATE
        ${GENERATED_DIR}/FWMANAGER_AIDL/include
    )
endif ()

target_compile_options(FWManagerClient PRIVATE
    -Wall -Wextra -std=c++17
)

target_link_libraries(FWManagerClient PRIVATE binder utils)

###########################################################
# Install the library
###########################################################
install(
    TARGETS
    fwmanager

    LIBRARY
    DESTINATION ${CMAKE_INSTALL_LIBDIR}
)

###########################################################
# Install the binary
###########################################################
install(
    TARGETS
    FWManagerService
    FWManagerClient

    RUNTIME
    DESTINATION ${CMAKE_INSTALL_BINDIR}
)
