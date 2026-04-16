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
import json
import yaml
import glob
import fnmatch
import subprocess
from subprocess import PIPE
from collections import defaultdict, deque


from logger import Logger

#_LOG_LEVEL = Logger.VERBOSE
_LOG_LEVEL = Logger.INFO
_LOG_TAG           = "aidl_interface"

logger = Logger(_LOG_TAG, _LOG_LEVEL)

def get_host_dir():
    return path.dirname(
            path.realpath(__file__))

AIDL_API_SUFFIX = "-api"
AIDL_PREPROCESSED_SUFFIX = "_interface"
AIDL_API_DIR = "aidl_api"
LANG_CPP = "cpp"
CURRENT_VERSION = "current"

TARGET_UPDATE_API = "update-api"
TARGET_FREEZE_API = "freeze-api"

""" Definition file to look for while locating interfaces
"""
INTERFACE_DEF_JSON = "interface.json"
INTERFACE_DEF_YAML  = "interface.yaml"

LIBRARIES_DEPENDENCIES_FILE = "dependencies.txt"

# Commands
CMD_AIDL = path.realpath(
        path.join(get_host_dir(), "../out/host/bin", "aidl")
        )
CMD_GEN_AIDL = path.realpath(
        path.join(get_host_dir(), "../build-aidl-generator-tool.sh")
        )
# TODO compile aidl_hash_gen in out directory
CMD_AIDL_HASH_GEN = path.join(get_host_dir(), "aidl_hash_gen")
CMD_INTERFACE_DEF_UPDATE = path.join(get_host_dir(), "interface-update.py")


def topological_sort(dependencies):
    indegree = {lib: 0 for lib in dependencies}
    for deps in dependencies.values():
        for dep in deps:
            indegree[dep] += 1

    queue = deque([lib for lib in dependencies if indegree[lib] == 0])
    sorted_order = []

    while queue:
        lib = queue.popleft()
        sorted_order.append(lib)
        for dep in dependencies[lib]:
            indegree[dep] -= 1
            if indegree[dep] == 0:
                queue.append(dep)

    if len(sorted_order) == len(dependencies):
        return sorted_order[::-1]
    else:
        raise ValueError("Cycle detected in dependencies")


def generate_libraries_dependencies(interfaces, out_dir):
    """ Generates list of versioned interface libraries and thier dependencies
    as per versions mentioned from all available interfaces.
    The list will be in a topological order so that the dependent libraries are
    in the beginning of the list.

    This is required to determine the order in which libraries must be included
    in the build

    Args:
        interfaces: List of all AIDL interfaces
        out_dir: Location of the directory where the list must be placed

    """

    dep_file = path.join(out_dir, LIBRARIES_DEPENDENCIES_FILE)
    if path.exists(dep_file):
        os.remove(dep_file)
    
    # Ensure output directory exists
    os.makedirs(out_dir, exist_ok=True)

    lib_deps_dict = defaultdict(list)
    for interface_name in list(interfaces.keys()):
        interface = interfaces[interface_name]
        # For frozen version
        for ver in list(interface.versions_with_info.keys()):
            lib_deps = [lib + "-cpp"
                    for lib in interface.versions_with_info[ver]]
            lib_deps_dict["%s-v%s-cpp" %(interface_name, ver)] = lib_deps
        # For Current version
        imports = interface.get_imports(interface.next_version())
        lib_deps = [imprt + "-vcurrent-cpp"
                for imprt in list(imports.keys())]
        lib_deps_dict["%s-vcurrent-cpp" %(interface_name)] = lib_deps


    libs_sorted = topological_sort(lib_deps_dict)

    for lib in libs_sorted:
        logger.verbose("%s: %s" %(lib, " ".join(lib_deps_dict[lib])))
        with open(dep_file, 'a') as file:
            file.write("%s: %s"
                    %(lib, " ".join(lib_deps_dict[lib])))
            file.write('\n')

    if path.exists(dep_file):
        logger.verbose("Library dependencies file generated at %s" %(dep_file))


def load_interfaces(interfaces_roots, out_dir, gen_dir=None, gen_lib_deps=False):
    """ Loads defined interfaces from provided directories

    Args:
        interfaces_roots: list of directory paths to look for interfaces

    Returns:
        List of AidlInterface Objects
    """

    # check if any directory needs to be skipped while looking for interfaces.
    # The environment variable will be set to the multiple directories seperated
    # by ","
    skip_dirs_raw = os.getenv("AIDL_VERSIONING_SKIP_DIR", "")
    defaults = ["examples", "docs", ".git", "site"] # Added docs and .git for safety
    
    if skip_dirs_raw == "":
        skip_dirs_raw = ",".join(defaults)
    else:
        skip_dirs_raw += "," + ",".join(defaults)
    interface_locations = []
    for interfaces_root in interfaces_roots:
        skip_paths = [path.join(interfaces_root, skip_dir) \
                for skip_dir in skip_dirs_raw.split(",")]
        logger.debug("Skipping Interfaces from the path %s" %(skip_paths))
        for root, dirs, files in os.walk(interfaces_root):
            dirs[:] = [d for d in dirs \
                    if path.join(root, d) not in skip_paths]
            if INTERFACE_DEF_JSON in files:
                interface_locations.append(path.join(root, INTERFACE_DEF_JSON))
            elif INTERFACE_DEF_YAML in files:
                interface_locations.append(path.join(root, INTERFACE_DEF_YAML))

    logger.debug("Interfaces found at %s" %(interface_locations))
    aidl_interfaces = {}
    for interface_loc in interface_locations:
        aidl_interface = AidlInterface(interfaces_roots, path.dirname(interface_loc),
                out_dir, gen_dir)
        if aidl_interface is not None:
            aidl_interfaces[aidl_interface.base_name] = aidl_interface

    # TODO: Do this only if interfaces are updated.
    # Need to find a way to check if interfaces are updated
    if gen_lib_deps:
        generate_libraries_dependencies(aidl_interfaces, out_dir)

    return aidl_interfaces


def has_version_suffix(moduleName):
    hasVersionSuffix = re.compile("-v\\d+$").match(moduleName)
    return hasVersionSuffix


def has_frozen_versions(interface):
    """ Check if the interface has any frozen versions (numbered versions like 1, 2, 3).
    
    Args:
        interface: The AidlInterface object to check
    
    Returns:
        True if frozen versions exist (e.g., stable/aidl/{module}/1/, stable/aidl/{module}/2/)
        False if only 'current' version exists
    """
    stable_aidl_dir = interface.interface_root_stable
    
    if not path.exists(stable_aidl_dir):
        return False
    
    # Check for numbered version directories (1, 2, 3, etc.)
    for entry in os.listdir(stable_aidl_dir):
        entry_path = path.join(stable_aidl_dir, entry)
        if path.isdir(entry_path) and entry.isdigit():
            return True
    
    return False


def validate_interface(interface, interfaces):
    """ Validate if the given interface file has valid interface defined
    Validations:
        1. aidl_interface is defined
        2. name is defined
        3. srcs are defined and exist(atlease one)
        4. if unstable, versions_with_info should not be defined
        5. versions_with_info has all versions defined as per frozen versions

    Args
        interface: The interface to validate
        interfaces: list of all loaded interfaces
    Returns
        api_dumps: API dump of all versions of the given interface.
    """

    current_api_dir = get_versioned_dir(interface,
            CURRENT_VERSION)
    if path.exists(current_api_dir):
        current_api_dump = ApiDump(
                interface.next_version(),
                current_api_dir,
                get_path_for_files(current_api_dir,
                    "*.aidl", True),
                path.join(current_api_dir, ".hash")
                )

    api_dumps = []
    
    # Only validate frozen versions if they actually exist on disk
    # During first update, interface.versions may list versions from YAML but dirs don't exist yet
    if has_frozen_versions(interface):
        for ver in interface.versions:
            api_dir = get_versioned_dir(interface, ver)
            if path.exists(api_dir):
                hash_file_path = path.join(api_dir, ".hash")
                dump = ApiDump(
                        ver,
                        api_dir,
                        get_path_for_files(api_dir, "*.aidl", True),
                        hash_file_path
                        )
                # TODO: should we check if hashfile exist?
                api_dumps.append(dump)
            else:
                # Version listed in YAML but directory doesn't exist - this is an error
                raise RuntimeError(f"API version {ver} path {api_dir} does not exist.")
    else:
        logger.verbose("No frozen versions exist for %s - skipping frozen version validation" 
                      %(interface.base_name))

    if path.exists(current_api_dir):
        api_dumps.append(current_api_dump)

    # Check for the Interfaces integrity and backword compatibility
    for i in range(len(api_dumps)):
        logger.verbose("api dump for version %s is %s" %(api_dumps[i].version, vars(api_dumps[i])))

        if path.exists(api_dumps[i].hash_file):
            check_integrity(interface, api_dumps[i])
        elif i != (len(api_dumps) - 1):
            # Only the current version will not have the hash file.
            assert False, "No hash file(%s) found for the frozen version %s" \
                    %(api_dumps[i].hash_file, api_dumps[i].version)

        if i == 0:
            continue

        # Compatibility check between adjacent versions
        checked = check_compatibility(interface, interfaces, api_dumps[i-1], api_dumps[i])

    return api_dumps


def get_path_for_files(src, pattern, rec=False):
    """
    Search and create a list of files with the given pattern.
    This list is required to find all aidl files available in the source directory.

    Args:
        src: Root directory to look for files
        pattern: pattern of file name. This could be directory structure or file
            extensions
        rec: Whether to search for files recursively.
    Return:
        file_paths: list of all files found as per give pattern.
    """
    file_paths = []
    if rec:
        for root, dirs, files in os.walk(src):
            for file in fnmatch.filter(files, pattern):
                file_paths.append(path.join(root, file))
    else:
        for files in pattern:
            file_paths.extend(glob.glob(path.join(src, files)))
    return file_paths


def get_versioned_dir(interface, version):
    """
    Get the location of versioned interface API for the given version.
    All versions are stored in stable/aidl/{module}/{version}/
    Args:
        interface: Interface of which versioned directory is required
        version: Version of the interface.
    Return:
        version_dir: location of the versioned Interface API
    """
    version_dir = path.join(interface.interface_root_stable, version)
    logger.debug("Directory for the version \"%s\" of \"%s\" is %s" \
            %(version, interface.base_name, version_dir))
    return version_dir


def get_preprocessed_dir(interface, version):
    """Get directory for preprocessed AIDL files (temporary build artifacts).
    
    These files are placed in out/.preprocessed/ to keep them separate from
    stable/ directory which contains version-controlled AIDL sources and
    generated C++ code that should be deployed.
    
    Args:
        interface: The AidlInterface object
        version: Version string (e.g., "1", "2", "current")
    
    Returns:
        Path to preprocessed directory: out/.preprocessed/{module}/{module}_interface/{version}/
    """
    # Use a dedicated .preprocessed directory in out/ for clarity
    # Extract workspace root from interface_root_stable path
    # interface_root_stable is typically: <workspace>/stable/aidl/{module}
    stable_path = interface.interface_root_stable
    workspace_root = path.dirname(path.dirname(path.dirname(stable_path)))  # Go up 3 levels
    
    preprocessed_root = path.join(workspace_root, "out", ".preprocessed", interface.base_name)
    return path.join(preprocessed_root,
            interface.base_name + AIDL_PREPROCESSED_SUFFIX, version)


def get_dependencies(interface, interfaces, version, is_freeze_api=False):
    """
    Get the list of versioned interfaces on which the given interface is dependant
    directly or indirectly.

    Args:
        interface: Interface for which dependencies are requested
        interfaces: All available interfaces
        version: Version of the interface for which dependencies are requested
        is_freeze_api: If the dependencies are requested while freezing the
            interface.

    Return:
        deps: List of preprocessed aidl of dependant interfaces
        imports: List of versiones Imports
        import_interfaces: List of interfaces from Imports

    """
    logger.verbose("Interface Name: %s" %(interface.base_name))

    # API version to look for in imports
    # Values:
    #       next: current version. i.e. latest frozen version + 1
    #       latest: last frozen version
    #       frozen: frozen version
    import_ver_type = ""

    if version == interface.next_version():
        # In case of a freeze_api, always use the latest version of
        # Imports.
        # This way we can make sure that the imported interface is
        # not modifed after freezing the api
        # In case of an error, imported interfaces must be frozen
        # transitively
        #
        # Otherwise(update_api and gen_sources) always use the next/current version.
        # This will be required when multiple interfaces are being modified/developed
        if is_freeze_api:
            import_ver_type = "latest"
        else:
            import_ver_type = "next"
    else:
        import_ver_type = "frozen"

    api_deps = ApiDependencies(interface.base_name, import_ver_type, version)
    logger.verbose("API Deps for %s: %s & %s" %(api_deps.interface_name, api_deps.import_ver_type, api_deps.version))
    api_deps = process_imports(interface, interfaces, api_deps)

    deps, imports, import_interfaces = list_dependencies(api_deps.api_dependecies)

    return deps, imports, import_interfaces

rec_counter = 0
def process_imports(interface, interfaces, api_deps):
    """
    Process imports for a particular version of the given interface.
    It travels through all the imports and identifies all the dependecies

    It will be called recursively to get all the indirect dependencies

    Args:
        interface: Interface for which imports needs be processed
        interfaces: List of all interfaces
        api_deps: object of ApiDependencies in which all dependencies captured
            recursively. It holds the interface name, version info.
    Return:
        api_deps: object of ApiDependencies in which all dependencies captured
            recursively. It holds the interface name, version info.
    """
    global rec_counter
    rec_counter += 1
    logger.verbose("Interface Name: %s, Version: %s, Recursion Count: %s" %(interface.base_name, api_deps.version, rec_counter))

    switch_version = False
    interface_version = api_deps.version
    imports = {}
    if api_deps.import_ver_type == "next":
        imports = interface.get_imports(interface.next_version())
        for imp in list(imports.keys()):
            imp_interface = interfaces[imp]
            api_deps.set_version(imp_interface.next_version())
            api_deps.set_name(imp_interface.base_name)
            api_deps = process_imports(imp_interface, interfaces, api_deps)

    elif api_deps.import_ver_type == "latest":
        if rec_counter == 1:
            # List of direct dependencies
            imports = interface.get_imports(interface.next_version())
        else:
            # List of indirect dependencies (dependencies of direct dependant interfaces)
            # get imports from latest frozen version
            
            # --- START FIX ---
            ver_to_check = interface.latest_version()
            
            # If "0", it means the interface has never been frozen. 
            # We must use the current/next version to find imports.
            if ver_to_check == "0":
                ver_to_check = interface.next_version()

            imports = interface.get_imports(ver_to_check)
            # --- END FIX ---

        for imp in list(imports.keys()):
            imp_interface = interfaces[imp]
            # Set version as per thier frozen versions
            # in case of unknown(case of direct dependencies), set it to the latest
            if imports[imp] == "unknown":
                # Check if the latest version is "0" (never frozen)
                # If so, use the next version (current)
                ver = imp_interface.latest_version()
                if ver == "0":
                    ver = imp_interface.next_version()
                api_deps.set_version(ver)
            else:
                api_deps.set_version(imports[imp])
            api_deps.set_name(imp_interface.base_name)
            api_deps = process_imports(imp_interface, interfaces, api_deps)

    elif api_deps.import_ver_type == "frozen":
        imports = interface.get_imports(interface_version)
        for imp in list(imports.keys()):
            imp_interface = interfaces[imp]
            api_deps.set_version(imports[imp])
            api_deps.set_name(imp_interface.base_name)
            api_deps = process_imports(imp_interface, interfaces, api_deps)

    if rec_counter != 1:
        logger.verbose("Addind Dependency %s-v%s" %(interface.base_name, interface_version))
        api_deps.add_dependency(interface, interface_version)
        api_deps.set_version(interface_version)
        api_deps.set_name(interface.base_name)

    rec_counter -= 1
    return api_deps


class ApiDependencies:

    # Name of the interface for which dependencies need to be evaluated
    interface_name = ""

    # Version of the interface for which dependencies need to be evaluated
    version = ""

    # Version of an imported hal to consider
    # Values:
    #   1. next: always consider the next version of imported hal and pick apis from current directory
    #   2. latest: always consider the last frozen version of an imported hal and pick apis from that particular versioned directory
    #   3. frozen: always consider the given frozen version of any imported hal and pick apis from that particular versioned directory
    import_ver_type = ""

    # List of all dependencies saved in dictionary format for easy access
    # key: Interface Name
    # Value: Dependency Info
    # Example:  {"interface_name":
    #               {"version"     :"",
    #                "preprocessed":"",
    #                "import"      :"",
    #                "Generated"   : ""
    #               }
    #           }
    api_dependecies = {}

    def __init__(self,
            interface_name,
            import_ver_type,
            version=None,
            ):
        if import_ver_type == "frozen" and not version:
            assert False, "version needs to be provided"
        self.interface_name = interface_name
        self.version = version
        self.import_ver_type = import_ver_type
        self.api_dependecies = {}

    def set_version(self, version):
        self.version = version

    def set_name(self, interface_name):
        self.interface_name = interface_name

    def add_dependency(self, interface, version):
        logger.verbose("Dependency for: %s, Import: %s, Version: %s" \
                %(interface.base_name, interface.base_name, version))

        if interface.base_name in list(self.api_dependecies.keys()):
            if int(self.api_dependecies[interface.base_name]["version"]) >= int(version):
                logger.debug("Dependency already exist for %s" %(interface.base_name))
                return
            else:
                del self.api_dependecies[interface.base_name]

        imprt = ""
        if version == interface.next_version():
            imprt = get_versioned_dir(interface, CURRENT_VERSION)
        else:
            imprt = get_versioned_dir(interface, version)
        preprocessed = get_preprocessed_dir(interface, version)

        aidl_gen_preprocessed(interface, version, self.api_dependecies)

        self.api_dependecies[interface.base_name] = {
                "version" : version,
                "preprocessed": preprocessed,
                "import": imprt
                }

    def append_preprocessed(self, preprocessed):
        self.preprocessed.append(preprocessed)

    def append_import(self, imprt):
        self.imports.append(imprt)

    def append_generated(self, generated):
        self.generated.append(generated)


def show_dep_error(interface_name):
    logger.error("The dependency resolution failed for %s" %(interface_name))
    logger.error("If this is not the interface you are processing, It must be directly or indirectly imported in your interface")

    logger.error("Firstly, make sure that the interface definition includes all direct dependant interfaces in it's imports")
    logger.error("\tIf you are updating an interface, make sure that imported interfaces are updated with the recent API changes you made")
    logger.error("\tIf you are freezing an interface, make sure that imported interfaces are frozen with the recent API changes which you updated")
    logger.error("\tIf you are generating sources, Please check your interface definition and make sure that the version with info is not modified manually.")


def aidl_gen_preprocessed(interface, version, api_deps):
    """
    Generates preprocessed AIDL file for given version which is required
    while resolving dependencies during aidl operations(Update API, Freeze API,
    and Generating sources)
    """
    logger.verbose("Interface Name: %s, Version: %s, Dependencies: %s" \
            %(interface.base_name, version, api_deps))

    srcs_versioned_dir = ""
    if interface.next_version() == version:
        srcs_versioned_dir = get_versioned_dir(interface, CURRENT_VERSION)
    else:
        srcs_versioned_dir = get_versioned_dir(interface, version)

    srcs = get_path_for_files(srcs_versioned_dir, interface.srcs)
    preprocessed = path.join(get_preprocessed_dir(interface, version), "preprocessed.aidl")

    imprt = ""
    if version == interface.next_version():
        imprt = get_versioned_dir(interface, CURRENT_VERSION)
    else:
        imprt = get_versioned_dir(interface, version)
    if not path.exists(imprt):
        logger.error("The import directory %s, does not exist." %(imprt))
        show_dep_error(interface.base_name)
        assert False, "Failed with the above error."

    # --- FIX START ---
    # Use a list instead of a string to prevent argument grouping errors
    optional_flags = []
    
    if interface.stability != "unstable":
        optional_flags.append("--stability=%s" % interface.stability)
    
    deps, _, _ = list_dependencies(api_deps)
    if len(deps) > 0:
        # Add each dependency as a separate flag in the list
        for dep in deps:
            optional_flags.append(f'-p{dep}')

    preprocess_gen_cmd = [CMD_AIDL,
            "--preprocess",
            preprocessed]
    
    # Extend the list with our optional flags
    preprocess_gen_cmd.extend(optional_flags)
            
    preprocess_gen_cmd.extend([
            "--structured",
            "-I"+imprt,
            ])
    # --- FIX END ---

    preprocess_gen_cmd.extend(srcs)

    logger.verbose("Command to generate Preprocessed AIDL: %s" %(preprocess_gen_cmd))
    if not exec_cmd(preprocess_gen_cmd):
        show_dep_error(interface.base_name)
        assert False, "Command failed."

def list_dependencies(api_deps):
    deps = []
    imprts = []
    import_interfaces = []
    for interface in list(api_deps.keys()):
        deps.append(path.join(api_deps[interface]["preprocessed"], "preprocessed.aidl"))
        imprts.append(api_deps[interface]["import"])
        import_interfaces.append("%s-v%s" %(interface, api_deps[interface]["version"]))

    return deps, imprts, import_interfaces


def version_for_hashgen(ver):
    # aidl_hash_gen uses the version before current version. If it has
    # never been frozen, return 'latest-version'.
    ver_int = int(ver)
    if ver_int > 1:
        return str(ver_int - 1)
    else:
        return "latest-version"


def check_api(interface, interfaces, oldDump, newDump, checkApiLevel,
        messageFile):
    """
    Compares two API and checks for equality or compatibility as per given
    argument.
    Aborts the operation in case of failure.

    Args:
        interface: AIDL Interface for which check is required
        interfaces: list of all all aidl interfaces
        oldDump: API dump of the old version
        newDump: API dump of new version
        checkApiLevel: type of check to carry out (equal or compatible)
    """
    newVersion = path.basename(newDump.api_dir)
    # TODO: Find: how these timestampfiles are used and whether they
    # are required
    timestampFile = path.join(interface.interface_api_dir_out,
            "checkapi_"+newVersion+".timestamp")

    # check_api
    optional_flags = []
    if interface.stability not in ["", "unstable"]:
        optional_flags.append("--stability=%s" %(interface.stability))

    # get dependent preprocessed interfaces from imports
    deps, imports, _ = get_dependencies(interface,
            interfaces, newDump.version)
    logger.verbose("Dependencies for %s: deps: %s, imports: %s" \
            %(interface.base_name, deps, imports))
    if len(deps) > 0:
        optional_flags.extend([f'-p {dep}' for dep in deps])

    checkApiCmd = [CMD_AIDL, "--checkapi="+checkApiLevel]
    checkApiCmd.extend(optional_flags)
    checkApiCmd.append(oldDump.api_dir)
    checkApiCmd.append(newDump.api_dir)

    touchCmd = ["touch", timestampFile]
    onErrorCmd = ["cat", messageFile]

    logger.verbose(checkApiCmd)
    
    # Run checkapi and capture output for better error reporting
    result = subprocess.run(checkApiCmd, capture_output=True, text=True)
    
    if result.returncode != 0:
        # error from --checkapi
        exec_cmd(onErrorCmd)
        logger.error("")
        logger.error("=" * 80)
        logger.error("AIDL Compatibility Check FAILED for %s" %(interface.base_name))
        logger.error("=" * 80)
        
        # Display AIDL compiler error output
        if result.stderr:
            logger.error("Detailed error from AIDL compiler:")
            logger.error(result.stderr)
        
        logger.error("")
        logger.error("IMPORTANT: Breaking changes are NOT permitted in AIDL versioned interfaces.")
        logger.error("Only the following changes are allowed:")
        logger.error("  ✓ ADD new methods at the END of an interface")
        logger.error("  ✓ ADD new fields at the END of a parcelable")
        logger.error("  ✓ ADD new enum values (with fallback handling)")
        logger.error("")
        logger.error("The following changes are FORBIDDEN:")
        logger.error("  ✗ Remove methods or fields")
        logger.error("  ✗ Change method signatures or field types")
        logger.error("  ✗ Reorder methods or fields")
        logger.error("  ✗ Rename methods or fields")
        logger.error("")
        logger.error("If you need to make breaking changes:")
        logger.error("  1. Create a NEW interface component (e.g., I%sNew)" %(interface.base_name.capitalize()))
        logger.error("  2. Leave the existing interface unchanged")
        logger.error("  3. Clients can migrate to the new interface at their own pace")
        logger.error("")
        logger.error("=" * 80)
        
        assert False, "Failed at check_api. Please update the module"
    else:
        # Create timestamp file directory if it doesn't exist (for pre-validation scenarios)
        timestamp_dir = path.dirname(timestampFile)
        os.makedirs(timestamp_dir, exist_ok=True)
        exec_cmd(touchCmd)

    return timestampFile


def check_equality(interface, interfaces, oldDump, newDump):
    """
    Compare two api dumps for the equality.
    """
    messageFile = path.join(get_host_dir(),
            "message_check_equality.txt")
    os.makedirs(interface.interface_api_dir_out, exist_ok=True)
    formattedMessageFile = path.join(interface.interface_api_dir_out,
            "message_check_equality.txt")
    logger.verbose("messageFile = %s\nformattedMessageFile = %s" \
            %(messageFile, formattedMessageFile))
    sed_cmd = ["sed", "s/%s/"+interface.base_name+"/g", messageFile]
    file_ = open(formattedMessageFile, "w")
    subprocess.Popen(sed_cmd, stdout=file_)

    return check_api(interface, interfaces, oldDump, newDump, "equal",
            formattedMessageFile)


def check_integrity(interface, api_dump):
    """
    Check the integrity of the given api dump of the versioned interface.
    Validates that AIDL files match their stored hash (in-memory check).
    """
    version = path.basename(api_dump.api_dir)
    messageFile = path.join(get_host_dir(),
            "message_check_integrity.txt")

    # Compute hash from AIDL files and compare to stored hash
    # If mismatch, display error message and exit
    hashGenCmd = "if [ `cd %s && { find ./ -name \"*.aidl\" -print0 | \
            LC_ALL=C sort -z | xargs -0 sha1sum && echo %s; } | \
            sha1sum | cut -d \" \" -f 1` = `tail -1 %s` ]; " + \
            "then true; else cat %s && exit 1; fi"
    hashGenCmd = hashGenCmd %(api_dump.api_dir,
            version_for_hashgen(api_dump.version), api_dump.hash_file,
            messageFile)

    logger.verbose(hashGenCmd)
    result = subprocess.call(hashGenCmd, shell=True)
    
    if result != 0:
        raise RuntimeError("Hash integrity check failed for %s version %s" 
                %(interface.base_name, version))


def check_compatibility(interface, interfaces, oldDump, newDump):
    messageFile = path.join(get_host_dir(), "message_check_compatibility.txt")
    return check_api(interface, interfaces, oldDump, newDump, "compatible", messageFile)


def check_for_development(interface, interfaces, latest_version_dump, tot_dump):
    logger.verbose("Interface Name: %s" %(interface.base_name))
    os.makedirs(interface.interface_api_dir_out, exist_ok=True)
    has_dev_path = path.join(interface.interface_api_dir_out, "has_development")
    rmCmd = ["rm", "-f", has_dev_path]

    has_development_cmd = ""
    if latest_version_dump != None:
        # genetaye optional flags
        optional_flags = []
        if interface.stability not in ["", "unstable"]:
            optional_flags.append("--stability=%s" %(interface.stability))

        # get dependent preprocessed interfaces from imports
        deps, imports, _ = get_dependencies(interface,
                interfaces, tot_dump.version)
        logger.verbose("Dependencies for %s: deps: %s, imports: %s" \
                %(interface.base_name, deps, imports))
        if len(deps) > 0:
            optional_flags.extend([f'-p {dep}' for dep in deps])

        has_development_cmd = "%s --checkapi=equal %s %s %s 2> /dev/null; echo $? > %s" \
                %(CMD_AIDL, " ".join(optional_flags), latest_version_dump.api_dir, tot_dump.api_dir, has_dev_path)
        logger.verbose(has_development_cmd)
    else:
        has_development_cmd = "echo 1 > %s" %(has_dev_path)

    subprocess.call(has_development_cmd, shell=True)

    return has_dev_path


class ApiDump:
    def __init__(self,
            version,
            api_dir,
            files,
            hash_file):
        self.version = version
        self.api_dir = api_dir
        self.files = files
        self.hash_file = hash_file


class AidlInterface:
    base_name = ""
    srcs = []
    # The directory where AIDL interfaces are being modified
    interface_root = ""
    # The directory where the stable version of AIDL interfaces are located.
    # location: <interfaces root directory>/stable/<stable_aidl_subdir>/<interface-name>/
    # Default: <interfaces root directory>/stable/aidl/<interface-name>/
    interface_root_stable = ""
    # The directory where stubs and proxies of stable AIDL interfaces are located.
    # location: <interfaces root directory>/stable/generated/<interface-name>/
    interface_gen_dir = ""
    # list of AIDL interfaces on which this interface depends upon.
    imports = []
    # list of frozen/stable versions  
    versions = []
    # key: version
    # value: list of versioned interfaces
    versions_with_info = {}
    stability = ""
    # location of frozen APIs: set the location where all frozen APIs must be kept
    # after freezing them.
    # values:
    #   stable: frozen versions will be kept at the root directory where all interfaces are
    #       located. A "stable/<stable_aidl_subdir>" directory will be created to keep frozen versions.
    #       The interfaces root directory should be the first in the list of root directories
    #       provided in "interfaces_roots" field.
    #   interface: frozen versions will be kept along with the AIDL interface.
    # This field cannot be changed once the first version is created.
    frozen_location = "stable"
    # Subdirectory name under stable/ for AIDL files (default: "aidl")
    # Can be overridden in interface.yaml via stable_aidl_subdir field
    stable_aidl_subdir = "aidl"
    # Locations of directories required for intermediatory operations
    interface_root_out = ""
    interface_api_dir_out = ""


    def __init__(self, interfaces_roots, interface_root, out_dir, gen_dir=None):
        """ Initializes aidl interface defined in interface_root path.
        It parses the interface.json defined in interface_root path and loads
        interface properties.

        These properties will be used while computing -freeze-api and -update-api

        args:
            interfaces_roots:   list of paths where all aidl interfaces are located.
            interface_root:     path where aidl interface is defined.
            interface_root_out: Out directory for Interface intermediate files
            interface_gen_out:  Directory to keep generated sources. If not provided,
                            interface_root_out will be used.
        """
        self.interface_root = path.realpath(interface_root)
        self._load_interface(interfaces_roots, out_dir, gen_dir)

    def _load_interface(self, interfaces_roots, out_dir, gen_dir):
        # TODO Add comments
        """
        """
        logger.verbose("Location:" + self.interface_root)
        data = None
        
        # --- DEBUGGING INSERT START ---
        # json_path = path.join(self.interface_root, INTERFACE_DEF_JSON)
        # yaml_path = path.join(self.interface_root, INTERFACE_DEF_YAML)
        # if path.exists(json_path):
        #     print(f"🛑 DEBUG: LOADING JSON FILE: {json_path}") # Explicit print
        #     with open(json_path, "r") as json_data:
        #         data = json.load(json_data)
        # elif path.exists(yaml_path):
        #     print(f"✅ DEBUG: LOADING YAML FILE: {yaml_path}") # Explicit print
        #     with open(yaml_path, "r") as yaml_data:
        #         data = yaml.safe_load(yaml_data)
        # --- DEBUGGING INSERT END ---
        
        if path.exists(path.join(self.interface_root, INTERFACE_DEF_JSON)):
            with open(path.join(self.interface_root, INTERFACE_DEF_JSON), "r") as json_data:
                data = json.load(json_data)
        elif path.exists(path.join(self.interface_root, INTERFACE_DEF_YAML)):
            with open(os.path.join(self.interface_root, INTERFACE_DEF_YAML), "r") as yaml_data:
                data = yaml.safe_load(yaml_data)
        else:
            logger.error("No interface is defined at %s" %(self.interface_root))
            return

        self.base_name = data.get("aidl_interface").get("name")

        # Read stable_aidl_subdir from interface.yaml (optional field, default: "aidl")
        self.stable_aidl_subdir = data.get("aidl_interface").get("stable_aidl_subdir", "aidl")

        self.frozen_location = data.get("aidl_interface").get("frozen_location", "stable")
        if self.frozen_location == "stable":
            # First directory in the list of interface root directory should
            # have the stable directory
            self.interface_root_stable = path.join(interfaces_roots[0], f"stable/{self.stable_aidl_subdir}", self.base_name)
            self.interface_gen_dir = path.join(interfaces_roots[0], "stable/generated", self.base_name)
        elif self.frozen_location == "interface":
            self.interface_root_stable = path.join(self.interface_root, "aidl_api")
            # TODO Needs to be updated
            self.interface_gen_dir = path.join(interfaces_roots[0], "stable/generated", self.base_name)

        self.srcs = data.get("aidl_interface").get("srcs")
        self.imports = data.get("aidl_interface").get("imports")
        if self.imports is None:
            self.imports = []
        self.stability = data.get("aidl_interface").get("stability")
        versions = []
        versions_with_info = {}
        ver_info = data.get("aidl_interface").get("versions_with_info")
        if ver_info is not None:
            for i in range(len(ver_info)):
                versions.append(str(i+1))
                versions_with_info[ver_info[i].get("version")] = ver_info[i].get("imports")
        self.versions = versions
        self.versions_with_info = versions_with_info

        logger.verbose("Interface Found: %s" %(self.base_name))
        logger.verbose("\tSources       = %s" %(self.srcs))
        logger.verbose("\tLocation      = %s" %(self.interface_root))
        logger.verbose("\tStable Location = %s" %(self.interface_root_stable))
        logger.verbose("\tImports       = %s" %(self.imports))
        logger.verbose("\tVersions      = %s" %(self.versions))
        logger.verbose("\tVersionsInfo  = %s" %(self.versions_with_info))
        logger.verbose("\tStability     = %s" %(self.stability))

        # Find which root directory this interface belongs to
        relative_path = None
        for root in interfaces_roots:
            real_root = path.realpath(root)
            if self.interface_root.startswith(real_root):
                relative_path = path.relpath(self.interface_root, start=real_root)
                break
        
        if relative_path is None:
            # Fallback if something weird happens (e.g. interface outside root)
            relative_path = path.relpath(self.interface_root, start="/")

        # Output directory for temporary build files (created on-demand)
        self.interface_root_out = path.join(out_dir, relative_path)
        # API temp directory - created on-demand when needed for temp files
        self.interface_api_dir_out = path.join(self.interface_root_out, self.base_name+AIDL_API_SUFFIX)


    def get_imports(self, version):
        # Dictionory
        # key: Interface Name
        # Value: version
        imports = {}

        if str(version) not in self.versions_with_info:
            # Given version is no frozen, load from self.imports
            logger.verbose("Given Version, %s is not a frozen for %s" %(version, self.base_name))
            if str(version) != self.next_version():
                # version should be always 1 in this case
                logger.error("Given Version, %s is neiher frozen nor "
                        "the \"next_version\" of %s"
                        %(version, self.base_name))
                show_dep_error(self.base_name)

                assert False, "Unknown version provided"

            for imp in self.imports:
                # let the called decide whether to use the next version or current version
                # for imports.
                imports[imp] = "unknown"

            return imports

        versioned_imports = self.versions_with_info[str(version)]
        for ver_imp in versioned_imports:
            name, _, ver = ver_imp.partition("-v")
            imports[name] = ver

        logger.verbose("Interface: %s, Version: %s, Imports: %s" %(self.base_name, version, imports))
        return imports


    def next_version(self):
        if self.stability == "unstable":
            return ""
        if len(self.versions) == 0:
            return "1"
        ver = self.versions[len(self.versions) -1]
        i = int(ver)
        return str(i+1)


    def latest_version(self):
        if self.stability == "unstable":
            return ""

        if len(self.versions) == 0:
            return "0"

        return self.versions[len(self.versions) -1]


    def versioned_name(self, version):
        """
        """

        return "%s-v%s" %(self.base_name, version)


def exec_cmd(cmd):
    # Don't join the list. Don't use shell=True.
    logger.debug("Running [%s]" %(" ".join(cmd))) # Logging string join is fine

    try:
        # Pass the list 'cmd' directly
        result = subprocess.run(cmd, stdout=PIPE, stderr=PIPE, encoding='utf-8', check=False)
        
        if result.returncode != 0:
            logger.error("Command failed: %s" %(" ".join(cmd)))
            logger.error(result.stderr)
            return False
            
        if result.stdout:
            print(result.stdout)
        return True
        
    except Exception as e:
        logger.error(f"Execution error: {e}")
        return False
