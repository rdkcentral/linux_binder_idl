#!/usr/bin/env python3

"""
    -r (--interfaces_roots)
    -u (--update_api)
    -f (--freeze_api)
    -g (--generate_source)
    -a (--generate_deps)
    -d (--gen_dir)
    -o (--out_dir)
"""


import sys
import getopt
import os
from os import path


from logger import Logger
import aidl_api
import aidl_gen_rule
from aidl_interface import CMD_AIDL


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
        logger.fatal("aidl is not installed at %s" %(CMD_AIDL))
        sys.exit(2)

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
        match o:
            case "-r" | "--interfaces_roots":
                for p in a.split(";"):
                    if path.exists(path.realpath(p)):
                        _intfs_roots.append(path.realpath(p))
                    else:
                        logger.warning(
                                "Provided path, %s, for interfaces doesn't exist." % (p))

            case "-u" | "--update_api":
                if _operation is None:
                    _operation = "update_api"
                else:
                    error = 1; # Multiple Operations

            case "-f" | "--freeze_api":
                if _operation is None:
                    _operation = "freeze_api"
                else:
                    error = 1; # Multiple Operations

            case "-g" | "--generate_source":
                if _operation is None:
                    _operation = "generate_source"
                else:
                    error = 1; # Multiple Operations

            case "-a" | "--generate_deps":
                if _operation is None:
                    _operation = "generate_deps"
                else:
                    error = 1; # Multiple Operations

            case "-d" | "--gen_dir":
                _gen_dir = a

            case "-d" | "--gen_dir":
                _gen_dir = a

            case "-v" | "--version":
                _gen_version = a

            case "-o" | "--out_dir":
                _out_dir = a

            case _:
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
