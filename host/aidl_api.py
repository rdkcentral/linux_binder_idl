#!/usr/bin/env python3

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
        CURRENT_VERSION, CMD_INTF_DEF_UPDATE
from logger import Logger

#_LOG_LEVEL = Logger.VERBOSE
_LOG_LEVEL = Logger.INFO
_LOG_TAG           = "aidl_api"

logger = Logger(_LOG_TAG, _LOG_LEVEL)



def make_api_dump_as_version(aidl_intf,
                                dump,
                                version,
                                latest_version_dump,
                                has_development=""):
    creating_new_version = version != CURRENT_VERSION
    target_dir = aidl_interface.get_versioned_dir(aidl_intf, version)
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
        copy_cmd = copy_cmd + "cp -rf %s/. %s; fi" %(dump.api_dir, target_dir)
        logger.verbose(copy_cmd)
        subprocess.call(copy_cmd, shell=True)

        change_message = "There is change between ToT version and the latest stable version. Freezing %s-V%s." \
                %(aidl_intf.base_name, version)
        no_change_message = "There is no change from the latest stable version of %s. Nothing happened."\
                %(aidl_intf.base_name)
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


def append_version(aidl_intf, aidl_intfs, version):
    imports = ""

    # TODO: update versioned imports
    imports = []
    for imprt in aidl_intf.imports:
        imprt_intf = aidl_intfs[imprt]
        imports.append("\"%s\"" %(imprt_intf.versioned_name(imprt_intf.latest_version())))

    intf_update_command = "if [ \"$(cat %s)\" = \"1\" ]; then " %(has_development)
    intf_update_command = intf_update_command + "%s -w -m %s " %(CMD_INTF_DEF_UPDATE, aidl_intf.base_name)
    intf_update_command = intf_update_command + "--parameter versions_with_info --add-literal "
    intf_update_command = intf_update_command + "'{\"version\": \"%s\", \"imports\": [%s]}' " %(version, ",".join(imports))
    intf_update_command = intf_update_command + "%s/interface; fi" %(aidl_intf.intf_root)

    logger.verbose(intf_update_command)
    subprocess.call(intf_update_command, shell=True)


def dependecies_check_for_freeze(aidl_intf, aidl_intfs):
    deps, imports, _ = aidl_interface.get_dependencies(aidl_intf,
            aidl_intfs, aidl_intf.next_version(), True)

    srcs = aidl_interface.get_path_for_files(aidl_intf.intf_root, aidl_intf.srcs)
    preprocessed = path.join(
            aidl_interface.get_preprocessed_dir(
                aidl_intf, aidl_intf.next_version()),
            "preprocessed.aidl")

    imprt = aidl_interface.get_versioned_dir(aidl_intf, CURRENT_VERSION)

    if not path.exists(imprt):
        logger.error("The import directory %s, does not exist." %(imprt))
        assert False, "Failed with the above error."

    optional_flags = ""
    if aidl_intf.stability != "unstable":
        optional_flags = optional_flags + "--stability=%s " %(aidl_intf.stability)
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

def update_hash_for_current_api(aidl_intf):
    hashgen_version = aidl_interface.version_for_hashgen(aidl_intf.next_version())
    api_dump_dir = aidl_interface.get_versioned_dir(aidl_intf, CURRENT_VERSION)
    hash_file = path.join(api_dump_dir, ".hash")
    hash_gen_cmd = [CMD_AIDL_HASH_GEN, api_dump_dir, hashgen_version, hash_file]
    subprocess.call(hash_gen_cmd)


def create_api_dump_from_source(aidl_intf, aidl_intfs, is_freeze_api=False):
    """ Creates api dump from the sources at the ToT (top of tree)
 
        Args:
            aidl_intf: AIDL interface for which api dump needs
                to be created.
            aidl_intfs: All available interfaces

        Return:
            tot_api_dump: API dump details
    """
    version = aidl_intf.next_version()

    if not path.exists(aidl_intf.intf_api_dir_out):
        os.makedirs(aidl_intf.intf_api_dir_out)

    api_dump_dir = path.join(aidl_intf.intf_api_dir_out, "dump")
    if path.exists(api_dump_dir):
        shutil.rmtree(api_dump_dir, ignore_errors=True)
    os.makedirs(api_dump_dir)

    hash_file = path.join(aidl_intf.intf_api_dir_out, "dump", ".hash")
    hashgen_version = aidl_interface.version_for_hashgen(version)

    # Get Input Files
    srcs = aidl_interface.get_path_for_files(aidl_intf.intf_root,
            aidl_intf.srcs)

    if srcs == None or len(srcs) == 0:
        assert False, "No sources found for in %s for %s" \
                %(aidl_intf.intf_root, aidl_intf.srcs)
    logger.verbose("Input Files: %s" %(srcs))

    optional_flags = []
    if aidl_intf.stability != "unstable":
        optional_flags.append("--stability=%s" %(aidl_intf.stability))

    # get dependent preprocessed interfaces from imports
    deps, imports, _ = aidl_interface.get_dependencies(aidl_intf,
            aidl_intfs, version, is_freeze_api)
    logger.verbose("Dependencies for %s: deps: %s, imports: %s" \
            %(aidl_intf.base_name, deps, imports))
    if len(deps) > 0:
        optional_flags.extend([f'-p{dep}' for dep in deps])

    # aidl and aidl_hash_gencommand to dump tot apis, these apis will
    # be checked against frozen and updated apis
    dump_cmd = [CMD_AIDL,
            "--dumpapi",
            "--structured",
            "-I"+aidl_intf.intf_root,
            "--out",
            api_dump_dir]
    dump_cmd.extend(optional_flags)
    dump_cmd.extend(srcs)
    hash_gen_cmd = [CMD_AIDL_HASH_GEN, api_dump_dir, hashgen_version, hash_file]

    logger.verbose("Dump API Command: %s" %(dump_cmd))
    logger.verbose("Hash Gen Command: %s" %(hash_gen_cmd))

    if not exec_cmd(dump_cmd):
        # TODO: Does it always fail because of unresolved dependencies
        aidl_interface.show_dep_error(aidl_intf.base_name)
        assert False, "command failed"

    subprocess.call(hash_gen_cmd)

    # Output Files
    api_files = aidl_interface.get_path_for_files(api_dump_dir,
            "*.aidl")
    if api_files == None or len(api_files) == 0:
        assert False, "Failed to dump APIs for %s" %(aidl_intf.base_name)

    logger.verbose("Output Files: %s" %(api_files))

    return ApiDump(version, api_dump_dir, api_files, hash_file)


def handle_update_api(intf_name, aidl_intfs):
    logger.verbose("Interface Name: %s" %(intf_name))

    aidl_intf = aidl_intfs[intf_name]

    if not aidl_intf.dump_api:
        logger.info("update_api is not supported for %s. dump api is disabled" %(aidl_intf.base_name))
        return

    # An API dump is created from source as tot_api_dump(Top of the Tree
    # API dump)  and it is compared against the API dump of the current
    tot_api_dump = \
            create_api_dump_from_source(
                                    aidl_intf,
                                    aidl_intfs)

    logger.info("Running %s-%s" %(aidl_intf.base_name, "update_api"))

    # API dump from source is updated to the 'current' version.
    # Triggered by `aidl_ops -u <interface name>`
    make_api_dump_as_version(aidl_intf, tot_api_dump,
            CURRENT_VERSION, None)

    # Validating interface after updating current API.
    # Check 1: Integrity
    #           Frozen APIs are not modified after freezing
    # Check 2: Compatibility
    #           All frozen versions and the current one are backword
    #           compatible
    # Note: Check 3 and 4 are not required in case of update API
    api_dumps = aidl_interface.validate_interface(aidl_intf, aidl_intfs)


def handle_freeze_api(intf_name, aidl_intfs):
    logger.verbose("Interface Name: %s" %(intf_name))

    aidl_intf = aidl_intfs[intf_name]

    # An API dump is created from source as
    # tot_api_dump(Top of the Tree API dump)  and it is compared against
    # the API dump of the current
    tot_api_dump = None
    if aidl_intf.dump_api:
        tot_api_dump = \
                create_api_dump_from_source(
                                        aidl_intf,
                                        aidl_intfs,
                                        is_freeze_api=True)

    logger.info("Running %s-%s" %(aidl_intf.base_name, "freeze_api"))

    # Check 1: Integrity
    #           Frozen APIs are not modified after freezing
    # Check 2: Compatibility
    #           All frozen versions and the current one are backword
    #           compatible
    api_dumps = aidl_interface.validate_interface(aidl_intf, aidl_intfs)

    # Check 3: Equality
    #           tot_api_dump is compared against the API dump of the
    #           'current' (yet-to-be-finalized) version.
    #           By checking this we enforce that any change in the AIDL
    #           interface is gated by the AIDL API review even before
    #           the interface is frozen as a new version.
    current_api_dir = aidl_interface.get_versioned_dir(aidl_intf,
            CURRENT_VERSION)
    current_api_dump = None
    if len(api_dumps) > 0 and \
            api_dumps[len(api_dumps)-1].version == aidl_intf.next_version():
        current_api_dump = api_dumps[len(api_dumps)-1]
        if aidl_intf.dump_api:
            checked = aidl_interface.check_equality(aidl_intf, aidl_intfs,
                    current_api_dump, tot_api_dump)
        else:
            update_hash_for_current_api(aidl_intf)
    else:
        # The "current" directory might not exist, in case when the
        # interface is first created.
        # Instruct user to create one by executing
        # `aidl_ops -u <Interface Name>`.
        logger.error("API dump for the current version of AIDL \
                interface %s does not exist." %(aidl_intf.base_name))
        logger.fatal("Run \"aidl_ops -u %s\", or add \"stability: \
                unstable\" to the build rule for the interface if it \
                does not need to be versioned" \
                %(aidl_intf.base_name))

    latest_version_dump = None
    if len(api_dumps) > 1:
        # The api_dumps[len(api_dumps)-1] is the current version
        latest_version_dump = api_dumps[len(api_dumps)-2]

    # Check 4: Updated
    #           Check for active development on the unfrozen version
    global has_development
    if aidl_intf.dump_api:
        has_development = aidl_interface.check_for_development(aidl_intf, aidl_intfs, latest_version_dump, tot_api_dump)
    else:
        has_development = aidl_interface.check_for_development(aidl_intf, aidl_intfs, latest_version_dump, current_api_dump)

    # Additional Check for dependencies when dump_api is disabled
    if not aidl_intf.dump_api:
        dependecies_check_for_freeze(aidl_intf, aidl_intfs)

    # API dump from source is frozen as the next stable version. Triggered by `m <name>-freeze-api`
    if aidl_intf.dump_api:
        make_api_dump_as_version(aidl_intf, tot_api_dump, aidl_intf.next_version(), latest_version_dump, has_development)
    else:
        make_api_dump_as_version(aidl_intf, current_api_dump, aidl_intf.next_version(), latest_version_dump, has_development)
    append_version(aidl_intf, aidl_intfs, aidl_intf.next_version())


def aidl_api(
        intf_name,
        operation,
        intfs_roots,
        out_dir):
    logger.debug  ("aidl_ops:")
    logger.debug  ("\tOperation        = %s" %(operation))
    logger.debug  ("\tInterface Name   = %s" %(intf_name))
    logger.verbose("\tInterfaces Roots = %s" %(intfs_roots))
    logger.verbose("\tOutput Directory = %s" %(out_dir))

    aidl_intfs = aidl_interface.load_interfaces(intfs_roots, out_dir)

    logger.verbose("Interfaces: %s" %(list(aidl_intfs)))

    if intf_name in aidl_intfs:
        logger.verbose("Interface(%s): %s" %(intf_name, aidl_intfs[intf_name]))
        logger.verbose("\tSources   = %s" %(aidl_intfs[intf_name].srcs))
        logger.verbose("\tLocation  = %s" %(aidl_intfs[intf_name].intf_root))
        logger.verbose("\tImports   = %s" %(aidl_intfs[intf_name].imports))
        logger.verbose("\tVersions  = %s" %(aidl_intfs[intf_name].versions))
        logger.verbose("\tStability = %s" %(aidl_intfs[intf_name].stability))
        logger.verbose("\tRoot Out  = %s" %(aidl_intfs[intf_name].intf_root_out))
        logger.verbose("\tAPI Out   = %s" %(aidl_intfs[intf_name].intf_api_dir_out))
    else:
        logger.fatal("Interface %s is not defined in the provided locations " % (intf_name))


    if operation is "update_api":
        handle_update_api(intf_name, aidl_intfs)
    elif operation is "freeze_api":
        handle_freeze_api(intf_name, aidl_intfs)

 
