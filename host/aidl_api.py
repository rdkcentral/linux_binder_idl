#!/usr/bin/env python3

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

import os
from os import path
import glob
import json
import subprocess
from subprocess import PIPE
import shutil
import fnmatch
import hashlib

import aidl_interface
from aidl_interface import AidlInterface
from aidl_interface import ApiDump
from aidl_interface import exec_cmd
from aidl_interface import CMD_AIDL, CMD_AIDL_HASH_GEN, \
        CURRENT_VERSION, CMD_INTERFACE_DEF_UPDATE
from logger import Logger

#_LOG_LEVEL = Logger.VERBOSE
_LOG_LEVEL = Logger.INFO
_LOG_TAG           = "aidl_api"

logger = Logger(_LOG_TAG, _LOG_LEVEL)



def make_api_dump_as_version(interface,
                                dump,
                                version,
                                has_development=""):
    """
    Make versioned API dump.
    If the version is current version, the api dump is carried during
    update api
    If the version is not the current version, the api dump is carried
    during freeze api

    Args:
        interface: AIDL interface for which api dump is required
        dump: API dump which will be versioned
        version: version for which API dump is required
        has_development: Path for the file to check if the interface is updated
        before freezing the version
    """

    creating_new_version = version != CURRENT_VERSION
    target_dir = aidl_interface.get_versioned_dir(interface, version)
    # We are asked to create a new version. But before doing that, check if the given
    # dump is the same as the latest version. If so, don't create a new version,
    # otherwise we will be unnecessarily creating many versions.
    # Copy the given dump to the target directory only when the equality check failed
    # (i.e. `has_development` file contains "1").

    # TODO: Should we handle transitive freeze?
    # transitive freeze: freeze APIs of imported interfaces.

    if creating_new_version:
        copy_cmd = "if [ \"$(cat %s)\" = \"1\" ]; then " %(has_development)
        copy_cmd = copy_cmd + "mkdir -p %s && " %(target_dir)
        copy_cmd = copy_cmd + "cp -rf %s/. %s;" %(dump.api_dir, target_dir)
        # Always remove the interface definition file from versioned APIs
        copy_cmd = copy_cmd + "rm -f %s/interface.yaml %s/interface.json;" %(target_dir, target_dir)
        copy_cmd = copy_cmd + "fi"
        logger.verbose(copy_cmd)
        subprocess.call(copy_cmd, shell=True)


        change_message = "There is change between ToT version and the latest stable version. Freezing %s-v%s." \
                %(interface.base_name, version)
        no_change_message = "There is no change from the latest stable version of %s. Nothing happened."\
                %(interface.base_name)
        message_command = "if [ \"$(cat %s)\" = \"1\" ]; then " %(has_development)
        message_command = message_command + "echo -e \"\033[0;32m%s\033[0m\"; else " %(change_message)
        message_command = message_command + "echo -e \"\033[0;31m%s\033[0m\"; fi" %(no_change_message)
        logger.verbose(message_command)
        subprocess.call(message_command, shell=True)
    else:
        update_command = "mkdir -p %s && rm -rf %s/* && cp -rf %s/* %s"\
                %(target_dir, target_dir, dump.api_dir, target_dir)
        logger.verbose(update_command)
        subprocess.call(update_command, shell=True)


def append_version(interface, interfaces, version):
    """
    Append the frozen version in the version_with_info field while freezing
    the api.

    Args:
        interface: AIDL interface for which version needs to be appended
        interfaces: List of all AIDL interfaces
        version: version to append
    """
    imports = ""

    # TODO: update versioned imports
    imports = []
    for imprt in interface.imports:
        imprt_interface = interfaces[imprt]
        imports.append("\"%s\"" %(imprt_interface.versioned_name(imprt_interface.latest_version())))

    interface_update_command = "if [ \"$(cat %s)\" = \"1\" ]; then " %(has_development)
    interface_update_command = interface_update_command + "%s -w -m %s " %(CMD_INTERFACE_DEF_UPDATE, interface.base_name)
    interface_update_command = interface_update_command + "--parameter versions_with_info --add-literal "
    interface_update_command = interface_update_command + "'{\"version\": \"%s\", \"imports\": [%s]}' " %(version, ",".join(imports))
    interface_update_command = interface_update_command + "%s/interface; fi" %(interface.interface_root)

    logger.verbose(interface_update_command)
    subprocess.call(interface_update_command, shell=True)


def dependecies_check_for_freeze(interface, interfaces):
    """
    Validates the dependencies before freezing of the AIDL interface API.
    Generates preprocessed AIDLs to validate dependecies.

    Args:
        interface: AIDL Interface for which check is required
        interfaces: list of all AIDL interfaces
    """

    deps, imports, _ = aidl_interface.get_dependencies(interface,
            interfaces, interface.next_version(), True)

    srcs = aidl_interface.get_path_for_files(interface.interface_root, interface.srcs)
    preprocessed = path.join(
            aidl_interface.get_preprocessed_dir(
                interface, interface.next_version()),
            "preprocessed.aidl")

    imprt = aidl_interface.get_versioned_dir(interface, CURRENT_VERSION)

    if not path.exists(imprt):
        logger.error("The import directory %s, does not exist." %(imprt))
        assert False, "Failed with the above error."

    optional_flags = ""
    if interface.stability != "unstable":
        optional_flags = optional_flags + "--stability=%s " %(interface.stability)
    if len(deps) > 0:
        optional_flags = optional_flags + " ".join([f'-p{dep}' for dep in deps]) + " "

    preprocess_gen_cmd = [CMD_AIDL,
            "--preprocess",
            preprocessed,
            optional_flags,
            "--structured",
            "-I"+imprt,
            ]

    preprocess_gen_cmd.extend(srcs)

    logger.verbose("Command to generate Preprocessed AIDL: %s" %(preprocess_gen_cmd))
    if not aidl_interface.exec_cmd(preprocess_gen_cmd):
        assert False, "Dependencies are not fullfilled"


def update_hash_for_current_api(interface):
    """
    Create a .hash file capturing the hash value for the given given interface
    and the next version which is being frozen.

    The version for the hash gen command is taken from aidl_interface which is
    not same as the frozen version. This is done to add bit more complexity while
    generating hash so that the hash value is not modified manually.

    Args:
        interface: AIDL interface for which hash is being generated
    """
    hashgen_version = aidl_interface.version_for_hashgen(interface.next_version())
    api_dump_dir = aidl_interface.get_versioned_dir(interface, CURRENT_VERSION)
    hash_file = path.join(api_dump_dir, ".hash")
    
    # Remove existing hash file to avoid appending (aidl_hash_gen uses >>)
    if path.exists(hash_file):
        os.remove(hash_file)
    
    hash_gen_cmd = [CMD_AIDL_HASH_GEN, api_dump_dir, hashgen_version, hash_file]
    subprocess.call(hash_gen_cmd)


def handle_update_api(interface_name, interfaces):
    logger.verbose("Interface Name: %s" %(interface_name))

    interface = interfaces[interface_name]

    logger.verbose("Running %s-%s" %(interface.base_name, "update_api"))

    # Copy AIDL source files from {module}/current/ to stable/aidl/{module}/current/
    current_api_dir = aidl_interface.get_versioned_dir(interface, CURRENT_VERSION)
    
    # PRE-COPY VALIDATION: Check compatibility BEFORE overwriting existing stable/aidl/
    # ONLY enforce compatibility if frozen versions exist (v1, v2, etc.)
    # If no frozen versions, current/ is free development - any changes allowed
    if path.exists(current_api_dir) and aidl_interface.has_frozen_versions(interface):
        logger.info("Pre-validating compatibility before updating %s" %(interface.base_name))
        logger.info("Frozen versions exist - enforcing backward compatibility")
        
        # Get existing stable API dump for comparison (OLD)
        existing_stable_dump = ApiDump(
            interface.next_version(),
            current_api_dir,
            aidl_interface.get_path_for_files(current_api_dir, "*.aidl", True),
            path.join(current_api_dir, ".hash")
        )
        
        # Create temporary API dump from source files (NEW)
        # Note: We use interface.interface_root directly since AIDL files are already there
        source_aidl_files = aidl_interface.get_path_for_files(
            interface.interface_root, "*.aidl", True)
        temp_source_dump = ApiDump(
            interface.next_version(),
            interface.interface_root,  # Use source directory directly
            source_aidl_files,
            None  # No hash file for source
        )
        
        # Check compatibility: new source must be compatible with existing stable
        try:
            logger.verbose("Checking compatibility: source vs existing stable")
            aidl_interface.check_compatibility(interface, interfaces, 
                                              existing_stable_dump, temp_source_dump)
            logger.info("Pre-validation passed: source changes are backward-compatible")
        except (AssertionError, RuntimeError) as e:
            logger.error("Pre-validation FAILED: Source changes are incompatible with existing stable API")
            logger.error("Error: %s" %(str(e)))
            logger.error("")
            logger.error("Breaking changes are NOT allowed in AIDL versioned interfaces.")
            logger.error("You can only ADD methods/fields/enums at the end.")
            logger.error("To make breaking changes, create a new interface (e.g., I%sNew)" %(interface.base_name.capitalize()))
            logger.error("")
            logger.error("Please revert your changes or create a new interface component.")
            raise RuntimeError("Compatibility validation failed - aborting update to prevent data corruption")
    elif path.exists(current_api_dir):
        logger.info("Pre-validation skipped for %s - no frozen versions yet (current/ is free development)" %(interface.base_name))
        # Optional: Log what changed for developer awareness
        logger.verbose("Changes detected since last update (informational only):")
        # Note: Could add diff summary here if desired
    else:
        logger.info("First update for %s - skipping pre-validation" %(interface.base_name))
    
    # Create target directory
    os.makedirs(current_api_dir, exist_ok=True)
    
    # Copy AIDL files from source to stable/aidl/{module}/current/
    logger.verbose("Copying AIDL files from %s to %s" %(interface.interface_root, current_api_dir))
    copy_cmd = "rsync -a --include='*/' --include='*.aidl' --exclude='*' %s/ %s/" %(interface.interface_root, current_api_dir)
    subprocess.call(copy_cmd, shell=True)
    
    # Generate/update hash for the current version in stable/aidl/{module}/current/
    update_hash_for_current_api(interface)

    # Validating interface after updating current API.
    # Check 1: Integrity
    #           Frozen APIs are not modified after freezing
    # Check 2: Compatibility
    #           All frozen versions and the current one are backward
    #           compatible
    # Note: Check 3 and 4 are not required in case of update API
    api_dumps = aidl_interface.validate_interface(interface, interfaces)


def handle_freeze_api(interface_name, interfaces):
    logger.verbose("Interface Name: %s" %(interface_name))

    interface = interfaces[interface_name]

    logger.verbose("Running %s-%s" %(interface.base_name, "freeze_api"))

    # Check 1: Integrity
    #           Frozen APIs are not modified after freezing
    # Check 2: Compatibility
    #           All frozen versions and the current one are backward
    #           compatible
    api_dumps = aidl_interface.validate_interface(interface, interfaces)

    # Check 3: Equality
    #           Current API hash is updated/verified
    current_api_dir = aidl_interface.get_versioned_dir(interface,
            CURRENT_VERSION)
    current_api_dump = None
    if len(api_dumps) > 0 and \
            api_dumps[len(api_dumps)-1].version == interface.next_version():
        current_api_dump = api_dumps[len(api_dumps)-1]
        update_hash_for_current_api(interface)
    else:
        # The "current" directory might not exist, in case when the
        # interface is first created.
        # Instruct user to create one by executing
        # `aidl_ops -u <Interface Name>`.
        logger.error("API dump for the current version of AIDL "
                "interface %s does not exist." %(interface.base_name))
        logger.fatal("Run \"aidl_ops -u %s\", or add \"stability: "
                "unstable\" to the build rule for the interface if it "
                "does not need to be versioned" %(interface.base_name))

    latest_version_dump = None
    if len(api_dumps) > 1:
        # The api_dumps[len(api_dumps)-1] is the current version
        latest_version_dump = api_dumps[len(api_dumps)-2]

    # Check 4: Updated
    #           Check for active development on the unfrozen version
    global has_development
    has_development = aidl_interface.check_for_development(interface, interfaces, latest_version_dump, current_api_dump)

    # Additional Check for dependencies
    dependecies_check_for_freeze(interface, interfaces)

    # API from current version is frozen as the next stable version. Triggered by freeze_api command
    make_api_dump_as_version(interface, current_api_dump, interface.next_version(), has_development)
    append_version(interface, interfaces, interface.next_version())


def aidl_api(
        interface_name,
        operation,
        interfaces_roots,
        out_dir):
    logger.debug  ("aidl_ops:")
    logger.debug  ("\tOperation        = %s" %(operation))
    logger.debug  ("\tInterface Name   = %s" %(interface_name))
    logger.verbose("\tInterfaces Roots = %s" %(interfaces_roots))
    logger.verbose("\tOutput Directory = %s" %(out_dir))

    interfaces = aidl_interface.load_interfaces(interfaces_roots, out_dir)
    if not interfaces:
        logger.fatal("No interfaces found at %s" %(interfaces_roots))

    logger.verbose("Interfaces: %s" %(list(interfaces)))

    if interface_name in interfaces:
        logger.verbose("Interface(%s): %s" %(interface_name, interfaces[interface_name]))
        logger.verbose("\tSources   = %s" %(interfaces[interface_name].srcs))
        logger.verbose("\tLocation  = %s" %(interfaces[interface_name].interface_root))
        logger.verbose("\tImports   = %s" %(interfaces[interface_name].imports))
        logger.verbose("\tVersions  = %s" %(interfaces[interface_name].versions))
        logger.verbose("\tStability = %s" %(interfaces[interface_name].stability))
        logger.verbose("\tRoot Out  = %s" %(interfaces[interface_name].interface_root_out))
        logger.verbose("\tAPI Out   = %s" %(interfaces[interface_name].interface_api_dir_out))
    else:
        logger.fatal("Interface %s is not defined in the provided locations " % (interface_name))

    if operation == "update_api":
        handle_update_api(interface_name, interfaces)
    elif operation == "freeze_api":
        handle_freeze_api(interface_name, interfaces)
 
