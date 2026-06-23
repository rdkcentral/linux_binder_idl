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
import shutil
import fnmatch
import re
import hashlib

import aidl_interface
from aidl_interface import AidlInterface
from aidl_interface import CMD_AIDL, CMD_AIDL_HASH_GEN, \
        CURRENT_VERSION, CMD_INTERFACE_DEF_UPDATE
from logger import Logger
from aidl_api import ApiDump

#_LOG_LEVEL = Logger.VERBOSE
_LOG_LEVEL = Logger.INFO
_LOG_TAG           = "aidl_gen_rule"

logger = Logger(_LOG_TAG, _LOG_LEVEL)


def get_imports_file(search_src, search_srcs, imports_dir, imports_dir_tot, import_files, import_files_tot):
    """
    Get all AIDL files as mentioned in the import statement.

    This is required while generating stubs and proxies and we don't want to generate the seperate library
    imported interfaces.

    Args:
    search_src: Source directory in which AIDLs needs to be searched
    search_srcs: List of all source directories where AIDLs might available
    imports_dir: Import Directory
    imports_dir_tot: Top-of-Tree Import directory
    import_files: All imported AIDLs. Found AIDL files will be saved in this list recursively.
    import_files_tot: All imported AIDLs from Top-of-tree

    """
    pattern = r'import\s+([\w\.]+);'
    lines = []
    imports = []
    with open(search_src, 'r') as src_fd:
        lines = src_fd.readlines()

    for line in lines:
        imports.extend(
                re.findall(pattern, line))
    logger.verbose("imports in %s: %s" %(search_src, imports))

    imports_path = []
    for imprt in imports:
        imports_path.append(imprt.replace('.', '/') + '.aidl')
    logger.verbose("imports_path in %s: %s" %(search_src, imports_path))

    imports_path_abs = [
            os.path.join(import_dir, import_path)
            for import_dir in imports_dir
            for import_path in imports_path
            if os.path.isfile(os.path.join(import_dir, import_path))
            ]
    logger.verbose("imports_path_abs in %s: %s" %(search_src, imports_path_abs))

    # In case dump api, we need to extract imports from tot apis,
    # as import statements will be removed in dumped apis
    # imports_dir_tot will be provided when dump api is enaled
    if len(imports_dir_tot) > 0:
        imports_path_abs_tot = [
                os.path.join(import_dir_tot, import_path)
                for import_dir_tot in imports_dir_tot
                for import_path in imports_path
                if os.path.isfile(os.path.join(import_dir_tot, import_path))
                ]
        logger.verbose("imports_path_abs_tot in %s: %s" %(search_src, imports_path_abs_tot))

        imports_path_abs_filtered_tot = [import_path_abs_tot
                for import_path_abs_tot in list(set(imports_path_abs_tot))
                if import_path_abs_tot not in search_srcs and
                import_path_abs_tot not in import_files_tot]

        for next_src_tot in imports_path_abs_filtered_tot:
            if next_src_tot != search_src:
                get_imports_file(next_src_tot, search_srcs, imports_dir, imports_dir_tot, import_files, import_files_tot)
                import_files_tot.append(next_src_tot)

    imports_path_abs_filtered = [import_path_abs
            for import_path_abs in list(set(imports_path_abs))
            if import_path_abs not in search_srcs and
            import_path_abs not in import_files]

    for next_src in imports_path_abs_filtered:
        # In case of imports_dir_tot is given, import files are already generated.
        if len(imports_dir_tot) == 0 \
                and next_src != search_src:
            get_imports_file(next_src, search_srcs, imports_dir, imports_dir_tot, import_files, import_files_tot)
        import_files.append(next_src)

    logger.verbose("Import Files: %s" %(import_files))
    logger.verbose("Import Files ToT: %s" %(import_files_tot))


def get_aidl_files_for_imports(interface, interfaces, imports_dir, import_interfaces, srcs):
    """
    Extract all import statements from AIDL Interfaces and find AIDL sources for them.

    This is required while generating stubs and proxies and we don't want to generate the seperate library
    imported interfaces.

    Args:
        interface: AIDL interface for which imported AIDLs need to be extracted
        interfaces: List of all AIDL interfaces
        imports_dir: Location of all Imports
        import_interfaces: List of Imported interfaces
        srcs: List of AIDL sources from which imports need to be extracted
    """
    srcs_imports = []
    import_files = []
    import_files_tot = []
    search_srcs = []
    imports_dir_tot = []

    # Identify files in which we can look for imports
    # Sources will have all required import statements
    search_srcs = srcs
    logger.verbose("Sources to Search for imports = %s" %(search_srcs))
    logger.verbose("Imports Locations = %s" %(imports_dir))

    # get all Imports
    pattern = r'import\s+([\w\.]+);'
    for search_src in search_srcs:
        get_imports_file(search_src, search_srcs, imports_dir, imports_dir_tot, import_files, import_files_tot)

    import_files = [import_file
            for import_file in import_files
            if import_file not in srcs
            ]

    logger.verbose("Import Files: %s" %(import_files))
    return import_files


def check_for_sources(dir_path):

    directory_exists = path.isdir(dir_path)
    has_content = False

    if directory_exists:
        contents = os.listdir(dir_path)
        if contents:
            has_content = True

    return has_content

def gen_cpp_sources(interface_name,
        interfaces,
        out_dir,
        gen_dir=None,
        gen_version=None):
    """
    Generate CPP stubs and proxies sources for the given aidl interface and version.
    If version is not provided, sources will be generated for the current version.

    Args:
        interface_name: Name of the interface for which sources are need to be generated
        interfaces: List of all aidl interface objects
        out_dir: Out directory for intermediate files
        gen_dir=None: Location at which to save sources.
                        If not given, a directory will be generated inside out directory
        gen_version=None: Version of the aidl interface for which sources needs to be generated.
                        If not given, sources will be generated for current the version

    """
    logger.verbose("Interface Name: %s, gen_dir=%s, gen_version=%s" %(interface_name, gen_dir, gen_version))

    interface = interfaces[interface_name]

    if gen_version is None:
        logger.debug("Generating sources for current unfrozen version")
        gen_version = interface.next_version()

    version_dir = ""
    if interface.layout == "module-local":
        # In module-local layout the version IS the interface's own
        # directory name (e.g. "current", "0.1.0.0").
        version_dir = path.basename(interface.interface_root)
    elif gen_version == interface.next_version():
        version_dir = CURRENT_VERSION
    else:
        version_dir = gen_version

    if gen_dir is None:
        logger.debug("Generating sources at default Location")
        gen_dir = path.join(interface.interface_gen_dir, "%s" %(version_dir), "src")
        gen_dir_inc = path.join(interface.interface_gen_dir, "%s" %(version_dir), "include")
    else:
        gen_dir_inc = path.join(gen_dir, "include")

    # skip if sources are already generated in case of non current version.
    # Always generate sources for current version
    if gen_version != interface.next_version():
        if check_for_sources(gen_dir) and check_for_sources(gen_dir_inc):
            logger.info("Sources are already generated for %s, version: %s at %s (Includes: %s" \
                    %(interface.base_name, gen_version, gen_dir, gen_dir_inc))

    logger.info("Generating sources for %s, version: %s at %s" \
            %(interface.base_name, gen_version, gen_dir))

    api_dir = aidl_interface.get_versioned_dir(interface, version_dir)
    logger.debug("API Directory: %s" %(api_dir))

    # Create API dump for the requested version
    api_dump = None
    if path.exists(api_dir):
        aidl_files = aidl_interface.get_path_for_files(api_dir, "*.aidl", True)
        if len(aidl_files) == 0 :
            assert False, "No AIDL sources are found for the Interface \
                    %s in %s" %(interface.base_name, api_dir)

        hash_file_path = path.join(api_dir, ".hash")
        api_dump = aidl_interface.ApiDump(
                                gen_version,
                                api_dir,
                                aidl_files,
                                hash_file_path)
    else:
        assert False, "Could not fine api directory, %s" %(api_dir)

    optional_flags = []
    if interface.stability != "unstable":
        optional_flags.append("--stability=%s" %(interface.stability))

    # get dependent preprocessed interfaces from imports
    deps, imports, import_interfaces = aidl_interface.get_dependencies(interface,
            interfaces, gen_version)
    logger.verbose("Dependencies for %s: deps: %s, imports: %s import_interfaces: %s" \
            %(interface.base_name, deps, imports, import_interfaces))
    # Include the location of versioned interface in import
    imports.insert(0, api_dir)
    if len(imports) > 0:
        optional_flags.extend([f'-I{imprt}' for imprt in imports])

    # It is not important for us, but the aidl gen rule needs to set it.
    # Set it to the Android's from where binder is ported.
    min_sdk_version = 33
    aidl_gen_cmd = \
            "%s --lang=cpp --structured --min_sdk_version=%s %s -h %s " %(CMD_AIDL, min_sdk_version, " ".join(optional_flags), gen_dir_inc)

    hash_gen = "notfrozen" # in case of current/unfrozen version
    if path.exists(api_dump.hash_file):
        with open(api_dump.hash_file, 'r') as file:
            hash_gen = file.read().replace('\n', '')

    # Emitted interface VERSION / getInterfaceVersion(). A module-local snapshot
    # may declare an explicit monotonic ordinal (interface.yaml `version:`) so a
    # frozen release reports a real version instead of always 1. This is
    # DECOUPLED from gen_version, which keys import/dependency resolution
    # (get_imports) and must stay at the resolution version. Invariant: an
    # explicit `version:` is only set on a frozen snapshot (real `.hash`); for
    # current/ it is unset, so emit_version == gen_version and HASH == notfrozen,
    # preserving existing behaviour. (#32)
    emit_version = gen_version
    if interface.layout == "module-local" and getattr(interface, "module_version", None):
        emit_version = str(interface.module_version)

    # include version and hash
    aidl_gen_cmd = aidl_gen_cmd + \
            "--version=%s --hash=%s " %(emit_version, hash_gen)

    aidl_gen_cmd = aidl_gen_cmd + \
            "--out=%s %s " %(gen_dir, " ".join(api_dump.files))

    """
    # Get aidl sources for imported interfaces.
    # This is required as we are using generated sources directly instead of library.
    srcs_imports = get_aidl_files_for_imports(interface, interfaces, imports, import_interfaces, api_dump.files)
    logger.verbose("Sources for imported Interfaces: %s" %(srcs_imports))
    aidl_gen_cmd = aidl_gen_cmd + "%s " %(" ".join(srcs_imports))
    """

    logger.verbose("AIDL Gen Command: %s" %(aidl_gen_cmd))

    result = subprocess.call(aidl_gen_cmd, shell=True)
    if result != 0:
        logger.error("AIDL compilation failed for %s version %s with exit code %d"
                     % (interface.base_name, gen_version, result))
        raise RuntimeError("AIDL compilation failed with exit code %d" % result)


def handle_source_gen(interface_name,
        interfaces,
        out_dir,
        gen_dir=None,
        gen_version=None):
    """
    Handle Generation of CPP stubs and proxies sources for the given aidl interface and version.
    Validates the interface before generating sources.

    If version is not provided, sources will be generated for the current version.

    Args:
        interface_name: Name of the interface for which sources are need to be generated
        interfaces: List of all aidl interface objects
        out_dir: Out directory for intermediate files
        gen_dir=None: Location at which to save sources.
                        If not given, a directory will be generated inside out directory
        gen_version=None: Version of the aidl interface for which sources needs to be generated.
                        If not given, sources will be generated for current the version

    """
    logger.verbose("Interface Name: %s" %(interface_name))

    interface = interfaces[interface_name]

    # Check 1: Integrity
    #           Frozen APIs are not modified after freezing
    # Check 2: Compatibility
    #           All frozen versions and the current one are backword
    #           compatible
    api_dumps = aidl_interface.validate_interface(interface, interfaces)

    if len(api_dumps) == 0 or \
            api_dumps[len(api_dumps)-1].version != interface.next_version():
        # The "current" directory might not exist, in case when the
        # interface is first created.
        # Instruct user to create one by executing
        # `aidl_ops -u <interface-name>`.
        logger.error("API dump for the current version of AIDL \
                interface %s does not exist." %(interface.base_name))
        logger.fatal("Run \"make %s-update-api\", or add \"stability: \
                unstable\" to the build rule for the interface if it \
                does not need to be versioned" \
                %(interface.base_name))

    if interface.stability == "unstable":
        # TODO: Implement
        return

    if gen_version is not None:
        if interface.layout == "module-local":
            # In module-local layout the version is selected by which
            # interface directory is built, not by a -v flag.
            logger.fatal("-v/--version is not applicable to module-local "
                    "interface %s; the version is its own directory (%s)"
                    %(interface.base_name,
                      path.basename(interface.interface_root)))
        if int(gen_version) < 1 or \
                int(gen_version) > int(interface.next_version()):
            logger.error("%s doesn have version %s, latest Available: %s" \
                    %(interface.base_name, gen_version, \
                    interface.next_version()))
            assert False, "Provide the correct version. Available versions \
                    %s & %s(current)" \
                    %(", ".join(interface.versions), interface.next_version())

    gen_cpp_sources(interface_name, interfaces, out_dir, gen_dir,
            gen_version)


def aidl_gen_rule(
        interface_name,
        interfaces_roots,
        out_dir,
        gen_dir=None,
        gen_version=None):

    logger.debug  ("aidl_ops:")
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

    handle_source_gen(interface_name, interfaces, out_dir, gen_dir, gen_version)


def aidl_gen_deps(
        interfaces_roots,
        out_dir):

    interfaces = aidl_interface.load_interfaces(interfaces_roots, out_dir, gen_lib_deps=True)
    if not interfaces:
        logger.fatal("No interfaces found at %s" %(interfaces_roots))


