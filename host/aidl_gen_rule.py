#!/usr/bin/env python3

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
        CURRENT_VERSION, CMD_INTF_DEF_UPDATE
from logger import Logger
from aidl_api import ApiDump

#_LOG_LEVEL = Logger.VERBOSE
_LOG_LEVEL = Logger.INFO
_LOG_TAG           = "aidl_gen_rule"

logger = Logger(_LOG_TAG, _LOG_LEVEL)


def get_imports_file(search_src, search_srcs, imports_dir, imports_dir_tot, import_files, import_files_tot):
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

def get_aidl_files_for_imports(aidl_intf, aidl_intfs, imports_dir, import_intfs, srcs):
    srcs_imports = []
    import_files = []
    import_files_tot = []
    search_srcs = []
    imports_dir_tot = []

    # Identify files in which we can look for imports
    if aidl_intf.dump_api:
        # if Dump api is enabled, provided sources won't have import statement
        # get them from top of the tree aidls
        search_srcs = aidl_interface.get_path_for_files(aidl_intf.intf_root, aidl_intf.srcs)
        for import_intf in import_intfs:
            name, _, _ = import_intf.partition("-V")
            imports_dir_tot.append(aidl_intfs[name].intf_root)
    else:
        # if dump api is disabled, provided sources will have all required import statements
        search_srcs = srcs
    logger.verbose("Sources to Search for imports = %s" %(search_srcs))
    logger.verbose("Imports Locations = %s" %(imports_dir))
    logger.verbose("Imports Location ToT = %s" %(imports_dir_tot))

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


def gen_cpp_sources(intf_name,
        aidl_intfs,
        out_dir,
        gen_dir=None,
        gen_version=None):
    logger.verbose("Interface Name: %s, gen_dir=%s, gen_version=%s" %(intf_name, gen_dir, gen_version))

    aidl_intf = aidl_intfs[intf_name]

    if gen_version is None:
        logger.debug("Generating sources for current unfrozen version")
        gen_version = aidl_intf.next_version()

    if gen_dir is None:
        logger.debug("Generating sources at default Location")
        gen_dir = path.join(aidl_intf.intf_root_out,
                    "%s-cpp-sources" %(aidl_intf.versioned_name(gen_version)),
                    "gen")

    logger.info("Generating sources for %s, version: %s at %s" \
            %(aidl_intf.base_name, gen_version, gen_dir))

    version_dir = ""
    if gen_version == aidl_intf.next_version():
        version_dir = CURRENT_VERSION
    else:
        version_dir = gen_version

    api_dir = aidl_interface.get_versioned_dir(aidl_intf, version_dir)
    logger.debug("API Directory: %s" %(api_dir))

    # Create API dump for the requested version
    api_dump = None
    if path.exists(api_dir):
        aidl_files = aidl_interface.get_path_for_files(api_dir, "*.aidl", True)
        if len(aidl_files) == 0 :
            assert False, "No AIDL sources are found for the Interface \
                    %s in %s" %(aidl_intf.base_name, api_dir)

        hash_file_path = path.join(api_dir, ".hash")
        api_dump = aidl_interface.ApiDump(
                                gen_version,
                                api_dir,
                                aidl_files,
                                hash_file_path)
    else:
        assert False, "Could not fine api directory, %s" %(api_dir)

    optional_flags = []
    if aidl_intf.stability != "unstable":
        optional_flags.append("--stability=%s" %(aidl_intf.stability))

    # get dependent preprocessed interfaces from imports
    deps, imports, import_intfs = aidl_interface.get_dependencies(aidl_intf,
            aidl_intfs, gen_version)
    logger.verbose("Dependencies for %s: deps: %s, imports: %s import_intfs: %s" \
            %(aidl_intf.base_name, deps, imports, import_intfs))
    # Include the location of versioned interface in import
    imports.insert(0, api_dir)
    if len(imports) > 0:
        optional_flags.extend([f'-I{imprt}' for imprt in imports])

    # It is not important for us, but the aidl gen rule needs to set it.
    # Set it to the Android's from where binder is ported.
    min_sdk_version = 33
    aidl_gen_cmd = \
            "%s --lang=cpp --structured --min_sdk_version=%s %s -h %s/include " %(CMD_AIDL, min_sdk_version, " ".join(optional_flags) ,gen_dir)

    hash_gen = "notfrozen" # in case of current/unfrozen version
    if path.exists(api_dump.hash_file):
        with open(api_dump.hash_file, 'r') as file:
            hash_gen = file.read().replace('\n', '')

    # include version and hash
    aidl_gen_cmd = aidl_gen_cmd + \
            "--version=%s --hash=%s " %(gen_version, hash_gen)

    aidl_gen_cmd = aidl_gen_cmd + \
            "--out=%s %s " %(gen_dir, " ".join(api_dump.files))

    """
    # Get aidl sources for imported interfaces.
    # This is required as we are using generated sources directly instead of library.
    srcs_imports = get_aidl_files_for_imports(aidl_intf, aidl_intfs, imports, import_intfs, api_dump.files)
    logger.verbose("Sources for imported Interfaces: %s" %(srcs_imports))
    aidl_gen_cmd = aidl_gen_cmd + "%s " %(" ".join(srcs_imports))
    """

    logger.verbose("AIDL Gen Command: %s" %(aidl_gen_cmd))

    subprocess.call(aidl_gen_cmd, shell=True)


def handle_source_gen(intf_name,
        aidl_intfs,
        out_dir,
        gen_dir=None,
        gen_version=None):
    logger.verbose("Interface Name: %s" %(intf_name))

    aidl_intf = aidl_intfs[intf_name]

    # Check 1: Integrity
    #           Frozen APIs are not modified after freezing
    # Check 2: Compatibility
    #           All frozen versions and the current one are backword
    #           compatible
    api_dumps = aidl_interface.validate_interface(aidl_intf, aidl_intfs)

    if len(api_dumps) == 0 or \
            api_dumps[len(api_dumps)-1].version != aidl_intf.next_version():
        # The "current" directory might not exist, in case when the
        # interface is first created.
        # Instruct user to create one by executing
        # `aidl_ops -u <interface-name>`.
        logger.error("API dump for the current version of AIDL \
                interface %s does not exist." %(aidlInterface.baseName))
        logger.fatal("Run \"make %s-update-api\", or add \"stability: \
                unstable\" to the build rule for the interface if it \
                does not need to be versioned" \
                %(aidlInterface.baseName))

    if aidl_intf.stability == "unstable":
        # TODO: Implement
        return

    if gen_version is not None:
        if int(gen_version) < 1 or \
                int(gen_version) > int(aidl_intf.next_version()):
            logger.error("%s doesn have version %s, latest Available: %s" \
                    %(aidl_intf.base_name, gen_version, \
                    aidl_intf.next_version()))
            assert False, "Provide the correct version. Available versions \
                    %s & %s(current)" \
                    %(", ".join(aidl_intf.versions), aidl_intf.next_version())

    gen_cpp_sources(intf_name, aidl_intfs, out_dir, gen_dir,
            gen_version)


def aidl_gen_rule(
        intf_name,
        intfs_roots,
        out_dir,
        gen_dir=None,
        gen_version=None):

    logger.debug  ("aidl_ops:")
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

    handle_source_gen(intf_name, aidl_intfs, out_dir, gen_dir, gen_version)


def aidl_gen_deps(
        intfs_roots,
        out_dir):

    aidl_intfs = aidl_interface.load_interfaces(intfs_roots, out_dir, gen_lib_deps=True)
