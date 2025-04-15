#!/usr/bin/env python3

"""
    aidl_ops -u|--update_api [OPTION]... INPUT...
        Performs update api for the given Interface

    aidl_ops -f|--freeze_api [OPTION]... INPUT...
        Performs freeze api for the given Interface

    aidl_ops -g|--generate_source [OPTION]... INPUT...
        Generates sources for the given Interface and version

    aidl_ops -a|--generate_deps [OPTION]... INPUT...
        Generates dependency tree of interface libraries(stubs and proxies)
        of interfaces defined in given directories

    OPTIONS:
        -r DIRS(--interfaces_roots=DIRS)
            ";" separated list of root directories where interfaces are located
        -u (--update_api)
            Perform update API for the given interface
        -f (--freeze_api)
            Perform Freeze API for the given interface
        -g (--generate_source)
            Generate Sources for the given Interface
        -a (--generate_deps)
            Generate interfaces libraries dependency tree
        -d DIR (--gen_dir=DIR)
            Directory path to generate sources.
        -o DIR (--out_dir=DIR)
            Build directory for intermediatory files

    INPUT:
        Interface Name

    OUTPUT:
        As per the operation selected
"""


import sys
import getopt
import os
from os import path


from logger import Logger
import aidl_api
import aidl_gen_rule
from aidl_interface import CMD_AIDL, CMD_GEN_AIDL, exec_cmd


#_LOG_LEVEL = Logger.VERBOSE
_LOG_LEVEL = Logger.INFO
_LOG_TAG           = "aidl_ops"


logger = Logger(_LOG_TAG, _LOG_LEVEL)


def parse_options(argv, docstring, opts="", long_opts=[]):
    logger.verbose("Parsing options")

    try:
        opts, args = getopt.getopt(argv, opts, long_opts)
    except getopt.GetoptError as err:
        logger.error("Exception occured while parsing arguments. err=%s" %(err))
        print(docstring)
        sys.exit(2)

    return opts, args


def get_host_dir():
    return path.dirname(
            path.realpath(__file__))


_intf_name = None
_operation = None
_intfs_roots = []

# Degault out Directory:
# workdir
# ├── host
# │   └──aidl_ops
# └── out
_out_dir = path.dirname(get_host_dir()) + "/out"
_gen_dir = None
_gen_version = None
_gen_deps = False


def handle_aidl_api():
    logger.verbose("handle %s" %(_operation))
    aidl_api.aidl_api(
            _intf_name,
            _operation,
            _intfs_roots,
            _out_dir)


def handle_aidl_gen_rule():
    aidl_gen_rule.aidl_gen_rule(
            _intf_name,
            _intfs_roots,
            _out_dir,
            _gen_dir,
            _gen_version
            )


def handle_aidl_gen_deps():
    aidl_gen_rule.aidl_gen_deps(
            _intfs_roots,
            _out_dir
            )


def main(argv):
    error = 0
    global _intf_name
    global _operation
    global _intfs_roots
    global _out_dir
    global _gen_dir
    global _gen_version
    global _gen_deps

    if not path.exists(CMD_AIDL):
        logger.info("Installed aidl at %s" %(CMD_AIDL))
        logger.info("Installation Script: %s" %(CMD_GEN_AIDL))
        exec_cmd([CMD_GEN_AIDL])
        

    _intfs_roots.append(os.getcwd())

    opts, args = parse_options(argv, __doc__,
            "r:ufgad:v:o:",
            ["interfaces_roots=",
                "update_api",
                "freeze_api",
                "generate_source",
                "generate_deps",
                "gen_dir=",
                "version="
                "out_dir="
                ])

    for o, a in opts:
        if o == "-r" or o == "--interfaces_roots":
            for p in a.split(";"):
                if path.exists(path.realpath(p)):
                    _intfs_roots.append(path.realpath(p))
                else:
                    logger.warning(
                            "Provided path, %s, for interfaces doesn't exist." % (p))

        elif o == "-u" or o == "--update_api":
            if _operation is None:
                _operation = "update_api"
            else:
                error = 1; # Multiple Operations

        elif o == "-f" or o == "--freeze_api":
            if _operation is None:
                _operation = "freeze_api"
            else:
                error = 1; # Multiple Operations

        elif o == "-g" or o == "--generate_source":
            if _operation is None:
                _operation = "generate_source"
            else:
                error = 1; # Multiple Operations

        elif o == "-a" or o == "--generate_deps":
            if _operation is None:
                _operation = "generate_deps"
            else:
                error = 1; # Multiple Operations

        elif o == "-d" or o == "--gen_dir":
            _gen_dir = a

        elif o == "-d" or o == "--gen_dir":
            _gen_dir = a

        elif o == "-v" or o == "--version":
            _gen_version = a

        elif o == "-o" or o == "--out_dir":
            _out_dir = a

        else:
            logger.error("Invalide argument, %s" %(o))

    if _operation != "generate_deps":
        if len(args) == 1:
            _intf_name = args[0]
        else:
            logger.fatal("No or more than one interfaces are provided")
            sys.exit(2)


    logger.debug("aidl_ops:")
    logger.debug  ("\tOperation        = %s" %(_operation))
    logger.debug  ("\tInterface Name   = %s" %(_intf_name))
    logger.verbose("\tInterfaces Roots = %s" %(_intfs_roots))
    logger.verbose("\tOutput Directory = %s" %(_out_dir))

    # TODO:
    #   1. Check for Error Codes
    #   2. Check if Interface Name is provided
    #   3. Warn about _gen_dir in case of update_api and freeze_api

    if _operation == "update_api" or _operation == "freeze_api":
        handle_aidl_api()
    elif _operation == "generate_source":
        logger.verbose("\tGen Directory    = %s" %(_gen_dir))
        logger.verbose("\tGen Version      = %s" %(_gen_version))
        handle_aidl_gen_rule()
    elif _operation == "generate_deps":
        handle_aidl_gen_deps()
    else:
        logger.error("unknown operation")
        sys.exit(2)



if __name__ == '__main__':
    main(sys.argv[1:])
