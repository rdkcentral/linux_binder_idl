#!/usr/bin/env python3

import os
from os import path
import json
import yaml
import os
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

LIBRARIES_DEPENDECIES_FILE = "dependencies.txt"

# Commands
# TODO compile aidl_hash_gen in out directory
CMD_AIDL = path.realpath(
        path.join(get_host_dir(), "../out", "aidl")
        )
CMD_AIDL_HASH_GEN = path.join(get_host_dir(), "aidl_hash_gen")
CMD_INTF_DEF_UPDATE = path.join(get_host_dir(), "intf-update")


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


def generate_libraries_dependencies(aidl_intfs, out_dir):
 
    dep_file = path.join(out_dir, LIBRARIES_DEPENDECIES_FILE)
    if path.exists(dep_file):
        os.remove(dep_file)

    lib_deps_dict = defaultdict(list)
    for intf_name in list(aidl_intfs.keys()):
        aidl_intf = aidl_intfs[intf_name]
        # For frozen version
        for ver in list(aidl_intf.versions_with_info.keys()):
            lib_deps = [lib + "-cpp"
                    for lib in aidl_intf.versions_with_info[ver]]
            lib_deps_dict["%s-V%s-cpp" %(intf_name, ver)] = lib_deps
        # For Current version
        imports = aidl_intf.get_imports(aidl_intf.next_version())
        lib_deps = [imprt + "-V%s-cpp" %(aidl_intfs[imprt].next_version())
                for imprt in list(imports.keys())]
        lib_deps_dict["%s-V%s-cpp" %(intf_name, aidl_intf.next_version())] = lib_deps


    libs_sorted = topological_sort(lib_deps_dict)

    for lib in libs_sorted:
        with open(dep_file, 'a') as file:
            file.write("%s: %s"
                    %(lib, " ".join(lib_deps_dict[lib])))
            file.write('\n')


def load_interfaces(intfs_roots, out_dir, gen_dir=None, gen_lib_deps=False):
    """ Loads defined interfaces from provided directories

    Args:
        intfs_roots: list of directory paths to look for interfaces

    Returns:
        List of AidlInterface Objects
    """

    intf_locations = []
    for intfs_root in intfs_roots:
        for root, dirs, files in os.walk(intfs_root):
            if INTERFACE_DEF_JSON in files:
                intf_locations.append(path.join(root, INTERFACE_DEF_JSON))
            elif INTERFACE_DEF_YAML in files:
                intf_locations.append(path.join(root, INTERFACE_DEF_YAML))

    aidl_interfaces = {}
    for intf_loc in intf_locations:
        aidl_interface = AidlInterface(path.dirname(intf_loc), out_dir, gen_dir)
        if aidl_interface is not None:
            aidl_interfaces[aidl_interface.base_name] = aidl_interface

    # TODO: Do this only if interfaces are updated.
    # Need to find a way to check if interfaces are updated
    if gen_lib_deps:
        generate_libraries_dependencies(aidl_interfaces, out_dir)

    return aidl_interfaces


def has_version_suffix(moduleName):
    hasVersionSuffix = re.compile("-V\\d+$").match(moduleName)
    return hasVersionSuffix


def validate_interface(aidl_intf, aidl_intfs):
    """ Validate if the given interface file has valid interface defined
    Validations:
        1. aidl_interface is defined
        2. name is defined
        3. srcs are defined and exist(atlease one)
        4. if unstable, versions_with_info should not be defined
        5. versions_with_info has all versions defined as per frozen versions
    """

    current_api_dir = get_versioned_dir(aidl_intf,
            CURRENT_VERSION)
    if path.exists(current_api_dir):
        current_api_dump = ApiDump(
                aidl_intf.next_version(),
                current_api_dir,
                get_path_for_files(current_api_dir,
                    "*.aidl", True),
                path.join(current_api_dir, ".hash")
                )

    api_dumps = []
    for ver in aidl_intf.versions:
        api_dir = get_versioned_dir(aidl_intf, ver)
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
            assert False, "API version %s path %s does not exist." %(ver, api_dir)

    if path.exists(current_api_dir):
        api_dumps.append(current_api_dump)

    # Check for the Interfaces integrity and backword compatibility
    for i in range(len(api_dumps)):
        logger.verbose("api dump for version %s is %s" %(api_dumps[i].version, vars(api_dumps[i])))

        if path.exists(api_dumps[i].hash_file):
            checkHashTimestamp = check_integrity(aidl_intf, api_dumps[i])
        elif i != (len(api_dumps) - 1):
            # Only the current version will not have the hash file.
            assert False, "No hash file(%s) found for the frozen version %s" \
                    %(api_dumps[i].hash_file, api_dumps[i].version)

        if i == 0:
            continue

        checked = check_compatibility(aidl_intf, aidl_intfs, api_dumps[i-1], api_dumps[i])

    return api_dumps


def get_path_for_files(src, pattern, rec=False, skip_dir=None):
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
    version_dir = ""
    if interface.dump_api:
        version_dir = path.join(interface.intf_root, AIDL_API_DIR,
                interface.base_name, version)
    else:
        if version is CURRENT_VERSION:
            version_dir = interface.intf_root
        else:
            version_dir = path.realpath(
                    path.join(interface.intf_root, "..", version)
                    )
    logger.verbose("Directory for the version \"%s\" is %s" \
            %(version, version_dir))
    return version_dir


def get_preprocessed_dir(aidl_intf, version):
    return path.join(aidl_intf.intf_root_out,
            aidl_intf.base_name + AIDL_PREPROCESSED_SUFFIX, version)


def get_dependencies(aidl_intf, aidl_intfs, version, is_freeze_api=False):
    logger.verbose("Interface Name: %s" %(aidl_intf.base_name))

    # API version to look for in imports
    # Values:
    #       next: current version. i.e. latest frozen version + 1
    #       latest: last frozen version
    #       frozen: frozen version
    import_ver_type = ""

    if version == aidl_intf.next_version():
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

    api_deps = ApiDependencies(aidl_intf.base_name, import_ver_type, version)
    logger.verbose("API Deps for %s: %s & %s" %(api_deps.intf_name, api_deps.import_ver_type, api_deps.version))
    api_deps = process_imports(aidl_intf, aidl_intfs, api_deps)

    deps, imports, import_intfs = list_dependencies(api_deps.api_dependecies)

    return deps, imports, import_intfs

rec_counter = 0
def process_imports(aidl_intf, aidl_intfs, api_deps):
    global rec_counter
    rec_counter += 1
    logger.verbose("Interface Name: %s, Version: %s, Recursion Count: %s" %(aidl_intf.base_name, api_deps.version, rec_counter))

    switch_version = False
    intf_version = api_deps.version
    imports = {}
    match api_deps.import_ver_type:
        case "next":
            imports = aidl_intf.get_imports(aidl_intf.next_version())
            for imp in list(imports.keys()):
                imp_intf = aidl_intfs[imp]
                api_deps.set_version(imp_intf.next_version())
                api_deps.set_name(imp_intf.base_name)
                api_deps = process_imports(imp_intf, aidl_intfs, api_deps)

        case "latest":
            if rec_counter == 1:
                # List of direct dependencies
                imports = aidl_intf.get_imports(aidl_intf.next_version())
            else:
                # List of indirect dependencies (dependencies of direct dependant interfaces)
                # get imports from latest frozen version
                imports = aidl_intf.get_imports(aidl_intf.latest_version())

            for imp in list(imports.keys()):
                imp_intf = aidl_intfs[imp]
                # Set version as per thier frozen versions
                # in case of unknown(case of direct dependencies), set it to the latest
                if imports[imp] == "unknown":
                    api_deps.set_version(imp_intf.latest_version())
                else:
                    api_deps.set_version(imports[imp])
                api_deps.set_name(imp_intf.base_name)
                api_deps = process_imports(imp_intf, aidl_intfs, api_deps)

        case "frozen":
            imports = aidl_intf.get_imports(intf_version)
            for imp in list(imports.keys()):
                imp_intf = aidl_intfs[imp]
                api_deps.set_version(imports[imp])
                api_deps.set_name(imp_intf.base_name)
                api_deps = process_imports(imp_intf, aidl_intfs, api_deps)


    if rec_counter != 1:
        logger.verbose("Addind Dependency %s-V%s" %(aidl_intf.base_name, intf_version))
        api_deps.add_dependency(aidl_intf, intf_version)
        api_deps.set_version(intf_version)
        api_deps.set_name(aidl_intf.base_name)

    rec_counter -= 1
    return api_deps

class ApiDependencies:

    # Name of the interface for which dependencies need to be evaluated
    intf_name = ""

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
    # Example:  {"intf_name":
    #               {"version"     :"",
    #                "preprocessed":"",
    #                "import"      :"",
    #                "Generated"   : ""
    #               }
    #           }
    api_dependecies = {}

    def __init__(self,
            intf_name,
            import_ver_type,
            version=None,
            ):
        if import_ver_type == "frozen" and not version:
            assert False, "version needs to be provided"
        self.intf_name = intf_name
        self.version = version
        self.import_ver_type = import_ver_type
        self.api_dependecies = {}

    def set_version(self, version):
        self.version = version

    def set_name(self, intf_name):
        self.intf_name = intf_name

    def add_dependency(self, aidl_intf, version):
        logger.verbose("Dependency for: %s, Import: %s, Version: %s" \
                %(aidl_intf.base_name, aidl_intf.base_name, version))

        if aidl_intf.base_name in list(self.api_dependecies.keys()):
            if int(self.api_dependecies[aidl_intf.base_name]["version"]) >= int(version):
                logger.debug("Dependency already exist for %s" %(aidl_intf.base_name))
                return
            else:
                del self.api_dependecies[aidl_intf.base_name]

        imprt = ""
        if version == aidl_intf.next_version():
            imprt = get_versioned_dir(aidl_intf, CURRENT_VERSION)
        else:
            imprt = get_versioned_dir(aidl_intf, version)
        preprocessed = get_preprocessed_dir(aidl_intf, version)

        aidl_gen_preprocessed(aidl_intf, version, self.api_dependecies)

        self.api_dependecies[aidl_intf.base_name] = {
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

def show_dep_error(intf_name):
    logger.error("The dependency resolution failed for %s" %(intf_name))
    logger.error("If this is not the interface you are processing, It must be directly or indirectly imported in your interface")

    logger.error("Firstly, make sure that the interface definition includes all direct dependant interfaces in it's imports")
    logger.error("\tIf you are updating an interface, make sure that imported interfaces are updated with the recent API changes you made")
    logger.error("\tIf you are freezing an interface, make sure that imported interfaces are frozen with the recent API changes which you updated")
    logger.error("\tIf you are generating sources, Please check your interface definition and make sure that the version with info is not modified manually.")


def aidl_gen_preprocessed(aidl_intf, version, api_deps):
    logger.verbose("Interface Name: %s, Version: %s, Dependencies: %s" \
            %(aidl_intf.base_name, version, api_deps))

    srcs_versioned_dir = ""
    if aidl_intf.next_version() == version:
        srcs_versioned_dir = get_versioned_dir(aidl_intf, CURRENT_VERSION)
    else:
        srcs_versioned_dir = get_versioned_dir(aidl_intf, version)

    srcs = get_path_for_files(srcs_versioned_dir, aidl_intf.srcs)
    preprocessed = path.join(get_preprocessed_dir(aidl_intf, version), "preprocessed.aidl")

    imprt = ""
    if version == aidl_intf.next_version():
        imprt = get_versioned_dir(aidl_intf, CURRENT_VERSION)
    else:
        imprt = get_versioned_dir(aidl_intf, version)
    if not path.exists(imprt):
        logger.error("The import directory %s, does not exist." %(imprt))
        show_dep_error(aidl_intf.base_name)
        assert False, "Failed with the above error."

    optional_flags = ""
    if aidl_intf.stability != "unstable":
        optional_flags = optional_flags + "--stability=%s " %(aidl_intf.stability)
    deps, _, _ = list_dependencies(api_deps)
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
    if not exec_cmd(preprocess_gen_cmd):
        show_dep_error(aidl_intf.base_name)
        assert False, "Command failed"


def list_dependencies(api_deps):
    deps = []
    imprts = []
    import_intfs = []
    for intf in list(api_deps.keys()):
        deps.append(path.join(api_deps[intf]["preprocessed"], "preprocessed.aidl"))
        imprts.append(api_deps[intf]["import"])
        import_intfs.append("%s-V%s" %(intf, api_deps[intf]["version"]))

    return deps, imprts, import_intfs


def version_for_hashgen(ver):
    # aidl_hash_gen uses the version before current version. If it has
    # never been frozen, return 'latest-version'.
    ver_int = int(ver)
    if ver_int > 1:
        return str(ver_int - 1)
    else:
        return "latest-version"


def check_api(aidl_intf, aidl_intfs, oldDump, newDump, checkApiLevel,
        messageFile):
    newVersion = path.basename(newDump.api_dir)
    # TODO: Find: how these timestampfiles are used and whether they
    # are required
    timestampFile = path.join(aidl_intf.intf_api_dir_out,
            "checkapi_"+newVersion+".timestamp")

    # check_api
    optional_flags = []
    if aidl_intf.stability not in ["", "unstable"]:
        optional_flags.append("--stability=%s" %(aidl_intf.stability))

    # get dependent preprocessed interfaces from imports
    deps, imports, _ = get_dependencies(aidl_intf,
            aidl_intfs, newDump.version)
    logger.verbose("Dependencies for %s: deps: %s, imports: %s" \
            %(aidl_intf.base_name, deps, imports))
    if len(deps) > 0:
        optional_flags.extend([f'-p {dep}' for dep in deps])

    checkApiCmd = [CMD_AIDL, "--checkapi="+checkApiLevel]
    checkApiCmd.extend(optional_flags)
    checkApiCmd.append(oldDump.api_dir)
    checkApiCmd.append(newDump.api_dir)

    touchCmd = ["touch", timestampFile]
    onErrorCmd = ["cat", messageFile]

    logger.verbose(checkApiCmd)
    if not exec_cmd(checkApiCmd):
        # error from --checkapi
        exec_cmd(onErrorCmd)
        assert False, "Failed at check_api. Please update the module"
    else:
        exec_cmd(touchCmd)

    return timestampFile


def check_equality(aidl_intf, aidl_intfs, oldDump, newDump):
    messageFile = path.join(get_host_dir(),
            "message_check_equality.txt")
    formattedMessageFile = path.join(aidl_intf.intf_api_dir_out,
            "message_check_equality.txt")
    logger.verbose("messageFile = %s\nformattedMessageFile = %s" \
            %(messageFile, formattedMessageFile))
    sed_cmd = ["sed", "s/%s/"+aidl_intf.base_name+"/g", messageFile]
    file_ = open(formattedMessageFile, "w")
    subprocess.Popen(sed_cmd, stdout=file_)

    return check_api(aidl_intf, aidl_intfs, oldDump, newDump, "equal",
            formattedMessageFile)


def check_integrity(aidl_intf, api_dump):
    version = path.basename(api_dump.api_dir)
    # TODO: Find: how these timestampfiles are used and whether they are
    # required
    timestampFile = path.join(aidl_intf.intf_api_dir_out,
            "checkhash_"+version+".timestamp")
    messageFile = path.join(get_host_dir(),
            "message_check_integrity.txt")

    # TODO: aidl files. hash file and message file is used as implicit,
    # check why

    hashGenCmd = "if [ `cd %s && { find ./ -name \"*.aidl\" -print0 | \
            LC_ALL=C sort -z | xargs -0 sha1sum && echo %s; } | \
            sha1sum | cut -d \" \" -f 1` = `tail -1 %s` ]; " + \
            "then touch %s; else cat %s && exit 1; fi"
    hashGenCmd = hashGenCmd %(api_dump.api_dir,
            version_for_hashgen(api_dump.version), api_dump.hash_file,
            timestampFile, messageFile)

    logger.verbose(hashGenCmd)
    subprocess.call(hashGenCmd, shell=True)

    return timestampFile


def check_compatibility(aidl_intf, aidl_intfs, oldDump, newDump):
    messageFile = path.join(get_host_dir(), "message_check_compatibility.txt")
    return check_api(aidl_intf, aidl_intfs, oldDump, newDump, "compatible", messageFile)


def check_for_development(aidl_intf, aidl_intfs, latest_version_dump, tot_dump):
    logger.verbose("Interface Name: %s" %(aidl_intf.base_name))
    has_dev_path = path.join(aidl_intf.intf_api_dir_out, "has_development")
    rmCmd = ["rm", "-f", has_dev_path]

    has_development_cmd = ""
    if latest_version_dump != None:
        # genetaye optional flags
        optional_flags = []
        if aidl_intf.stability not in ["", "unstable"]:
            optional_flags.append("--stability=%s" %(aidl_intf.stability))

        # get dependent preprocessed interfaces from imports
        deps, imports, _ = get_dependencies(aidl_intf,
                aidl_intfs, tot_dump.version)
        logger.verbose("Dependencies for %s: deps: %s, imports: %s" \
                %(aidl_intf.base_name, deps, imports))
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
    intf_root = ""
    imports = []
    versions = []
    # key: version
    # value: list of versioned interfaces
    versions_with_info = {}
    stability = ""
    dump_api = False
    intf_root_out = ""
    intf_api_dir_out = ""
    intf_gen_dir_out = ""


    def __init__(self, intf_root, out_dir, gen_dir=None):
        """ Initializes aidl interface defined in intf_root path.
        It parses the interface.json defined in intf_root path and loads
        interface properties.

        These properties will be used while computing -freeze-api and -update-api

        args:
            intf_root:     path where aidl interface is defined.
            intf_root_out: Out directory for Interface intermediate files
            intf_gen_out:  Directory to keep generated sources. If not provided,
                            intf_root_out will be used.
        """
        self.intf_root = path.realpath(intf_root)
        self._load_interface(out_dir, gen_dir)


    def _load_interface(self, out_dir, gen_dir):
        # TODO Added comments
        """
        """
        logger.verbose("Location:" + self.intf_root)
        data = None
        if path.exists(path.join(self.intf_root, INTERFACE_DEF_JSON)):
            with open(path.join(self.intf_root, INTERFACE_DEF_JSON), "r") as json_data:
                data = json.load(json_data)
        elif path.exists(path.join(self.intf_root, INTERFACE_DEF_YAML)):
            with open(os.path.join(self.intf_root, INTERFACE_DEF_YAML), "r") as yaml_data:
                data = yaml.safe_load(yaml_data)
        else:
            logger.error("No interface is defined at %s" %(self.intf_root))
            return

        self.base_name = data.get("aidl_interface").get("name")
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

        dump_api = data.get("aidl_interface").get("dump_api")
        if dump_api == "enabled":
            self.dump_api = True

        logger.verbose("Interface Found: %s" %(self.base_name))
        logger.verbose("\tSources       = %s" %(self.srcs))
        logger.verbose("\tLocation      = %s" %(self.intf_root))
        logger.verbose("\tImports       = %s" %(self.imports))
        logger.verbose("\tVersions      = %s" %(self.versions))
        logger.verbose("\tVersionsInfo  = %s" %(self.versions_with_info))
        logger.verbose("\tStability     = %s" %(self.stability))

        self.intf_root_out = path.join(out_dir, path.relpath(self.intf_root, start="/"))
        if not path.exists(self.intf_root_out):
            os.makedirs(self.intf_root_out)

        self.intf_api_dir_out = path.join(self.intf_root_out, self.base_name+AIDL_API_SUFFIX)
        if not path.exists(self.intf_api_dir_out):
            os.makedirs(self.intf_api_dir_out)


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
            name, _, ver = ver_imp.partition("-V")
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

        return "%s-V%s" %(self.base_name, version)


def exec_cmd(cmd):
    logger.verbose("Running [%s]" %(" ".join(cmd)))

    result = subprocess.run(" ".join(cmd), stdout=PIPE, stderr=PIPE, shell=True)
    if result.returncode:
        logger.error("The command [%s] returned unsuccessful result" \
                %(" ".join(cmd)))
        logger.error("%s" %(result.stderr.decode('utf-8')))
        return False
    else:
        if len(result.stdout.decode('utf-8')) > 0:
            print("%s" %(result.stdout.decode('utf-8')))

    return True
