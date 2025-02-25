#!/usr/bin/env python3

"""
-add-literal value
    a literal to add
-m value
    comma or whitespace separated list of modules on which to operate
-parameter name
    alias to -property=name
-property name
    fully qualified name of property to modify (default "deps")
-remove-property
    remove the property
-w  write result to (source) file instead of stdout
"""
# ASSUMPTIONS:
#   1. Each interface.json will have only one aidl Interface Defined.
#

import sys
import os
import getopt
import os
from os import path
import json
#import yaml
from ruamel.yaml import YAML
import ast
from collections import OrderedDict
from copy import deepcopy

import aidl_interface

yaml = YAML()
yaml.preserve_quotes = True
yaml.indent(mapping=2, sequence=4, offset=2)

DEBUG = False

moduleNames = []
writeResult = False
addLiteral = {}
propertyName = None
removeProperty = False
inputFiles = []

MODULE_TYPE_INTERFACE = "aidl_interface"
MODULE_KEY_NAME = "name"
MODULE_KEY_SRCS = "srcs"
MODULE_KEY_STABILITY = "stability"
MODULE_KEY_VERSIONSWITHINFO = "versions_with_info"
MODULE_KEY_VERSION = "version"
MODULE_KEY_IMPORTS = "imports"

def update_versions_with_info(versionWithInfo, addLiteral):
    """ updare the versions_with_info field with the provided addLiteral.
    expected addLiteral is a dictionary in string format.
    Convert it to the ordered dictionary and append it to the provided versionWithInfo.
    if versionWithInfo is null create one.
    """
    addLiteralDict = ast.literal_eval(addLiteral)

    addLiteralODict = OrderedDict([
                        (MODULE_KEY_VERSION, None),
                        (MODULE_KEY_IMPORTS, None)
                        ])

    addLiteralODict[MODULE_KEY_VERSION] = addLiteralDict[MODULE_KEY_VERSION]
    addLiteralODict[MODULE_KEY_IMPORTS] = addLiteralDict[MODULE_KEY_IMPORTS]

    versionWithInfoUpdated = []
    for i in range(len(versionWithInfo)):
        versionWithInfoUpdated.append(versionWithInfo[i])
    versionWithInfoUpdated.append(addLiteralDict)

    if DEBUG:
        print("%s: %s" %(MODULE_KEY_VERSIONSWITHINFO, versionWithInfoUpdated))

    return versionWithInfoUpdated


def process_file(file):
    #if  len(aidl_interface.validate_interface(file)) == 0:
    #    print("Invalid Interface Definition" %(file))
    #    return

    data = None
    file_type = None
    if path.exists(file+".json"):
        _file = file + ".json"
        file_type = "json"
    elif path.exists(file+".yaml"):
        _file = file + ".yaml"
        file_type = "yaml"
    else:
        print("File %s.(json/yaml) doesn't exist" %(file))
        return

    with open(_file, "r") as file_fd:
        if file_type == "json":
            data = json.load(file_fd)
        elif file_type == "yaml":
            data = yaml.load(file_fd)

    for moduleName in moduleNames:
        if data[MODULE_TYPE_INTERFACE][MODULE_KEY_NAME] != moduleName:
            # given module is of MODULE_TYPE_INTERFACE and it exist in the file
            print("module %s is not defined in the interface %s" %(moduleName, file))
            continue
        if DEBUG:
            print("updating module %s " %(moduleName))
        module = data[MODULE_TYPE_INTERFACE]

        if propertyName == MODULE_KEY_VERSIONSWITHINFO:
            if MODULE_KEY_VERSIONSWITHINFO in module:
                versionWithInfo = module[MODULE_KEY_VERSIONSWITHINFO]
            else:
                versionWithInfo = []
            versionWithInfo = update_versions_with_info(versionWithInfo, addLiteral)
            module[MODULE_KEY_VERSIONSWITHINFO] = versionWithInfo
        else:
                print("unknown property/parameter %s" %(propertyName))

        data[MODULE_TYPE_INTERFACE] = module
        if DEBUG:
            print("Interface after Update: %s" %(data))

    # TODO: Enable it on completion
    with open(_file, "w") as file_fd:
        if file_type == "json":
            json.dump(data, file_fd, indent=4)
        elif file_type == "yaml":
            yaml.dump(data, file_fd)

def main(argv):

    extra_opts = "m:w"
    extra_long_opts = [
            "add-literal=",
            "parameter=",
            "property=",
            "remove-property",
            "help"
            ]

    opts, args = getopt.getopt(
            argv, extra_opts, extra_long_opts)

    for o, a in opts:
        if o in ("-m"):
            global moduleNames
            moduleNames = a.replace(",", " ").split()
        elif o in ("-w"):
            global writeResult
            writeResult = True
        elif o in ("--add-literal"):
            global addLiteral
            addLiteral = a
        elif o in ("--property", "--parameter"):
            global propertyName
            propertyName = a
        elif o in ("--remove-property"):
            global removeProperty
            removeProperty = True
        elif o in ("--help"):
            print(sys.__doc__)
        else:
            assert False, "unknown option \"%s\"" % (o,)

    global inputFiles
    for i in args:
        inputFiles.append(i)

    if DEBUG:
        # TODO: Improvise these DEBUG prints
        print(moduleNames)
        print(writeResult)
        print(addLiteral)
        print(propertyName)
        print(removeProperty)
        print(inputFiles)

    if propertyName == None:
        assert False, "parameter/property name is required"

    if len(moduleNames) == 0:
        assert False, "-m parameter is required"

    if not removeProperty and len(addLiteral) == 0:
        assert False, "--add-literal, or --remove-property is required"

    if len(inputFiles) == 0:
        assert False, "Input file is required"

    for i in inputFiles:
        process_file(i)


if __name__ == '__main__':
    main(sys.argv[1:])
