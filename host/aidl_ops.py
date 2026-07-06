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

    aidl_ops dump-surface <aidl-root> [--out FILE]
        Prints a canonical, deterministic text dump of the AIDL surface
        declared under <aidl-root> (see host/aidl_surface.py)

    aidl_ops diff-surface <old-dump> <new-dump> [--json]
        Structurally compares two dump-surface outputs and classifies the
        change as breaking / major / none (see host/aidl_surface.py)

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


_interface_name = None
_operation = None
_interfaces_roots = []


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
            _interface_name,
            _operation,
            _interfaces_roots,
            _out_dir)


def handle_aidl_gen_rule():
    logger.debug("handle %s" %(_operation))
    aidl_gen_rule.aidl_gen_rule(
            _interface_name,
            _interfaces_roots,
            _out_dir,
            _gen_dir,
            _gen_version
            )


def handle_aidl_gen_deps():
    logger.debug("handle %s" %(_operation))
    aidl_gen_rule.aidl_gen_deps(
            _interfaces_roots,
            _out_dir
            )


def main(argv):
    # Surface subcommands (#27) are self-contained and bypass getopt.
    if argv and argv[0] in ("dump-surface", "diff-surface"):
        import aidl_surface
        sys.exit(aidl_surface.main(argv))

    error = 0
    global _interface_name
    global _operation
    global _interfaces_roots
    global _out_dir
    global _gen_dir
    global _gen_version
    global _gen_deps

    opts, args = parse_options(argv, __doc__,
            "r:ufgad:v:o:h",
            ["interfaces_roots=",
                "update_api",
                "freeze_api",
                "generate_source",
                "generate_deps",
                "gen_dir=",
                "version=",
                "out_dir=",
                "help"
                ])

    for o, a in opts:
        if o == "-r" or o == "--interfaces_roots":
            for p in a.split(";"):
                if path.exists(path.realpath(p)):
                    _interfaces_roots.append(path.realpath(p))
                else:
                    logger.error(
                            "Provided path, %s, for interfaces doesn't exist." %(p))

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
            # Version is passed through verbatim. Integer ordinals ("1", "2")
            # and dotted release strings ("0.1.0.0") are both valid — the
            # latter is used by repos that pin imports via "name@X.Y.Z.W"
            # in interface.yaml (linux_binder_idl#23). The value is treated
            # as an opaque directory-name component downstream.
            _gen_version = a.strip()

        elif o == "-o" or o == "--out_dir":
            _out_dir = a

        elif o == "-h" or o == "--help":
            print(__doc__)
            sys.exit(0)

        else:
            logger.error("Invalide argument, %s" %(o))
            sys.exit(1)

    if not _interfaces_roots:
        logger.warning("No root directory for AIDL interfaces is provided.")
        logger.info("setting it to %s" %(os.getcwd()))
        _interfaces_roots.append(os.getcwd())

    if _operation is None:
        logger.error("No AIDL operation provided")
        sys.exit(1)

    if error == 1:
        logger.error("More than one AIDL operation provided")
        sys.exit(1)

    # exactly one interface should be provided in all all operations
    # except while generating dependencies
    if _operation != "generate_deps":
        if len(args) == 1:
            _interface_name = args[0]
        else:
            logger.fatal("No or more than one interfaces are provided")
            sys.exit(1)

    # check if aidl tool is available. If not generate it.
    if not path.exists(CMD_AIDL):
        logger.error("AIDL tool not found, Installation Script: %s" %(CMD_GEN_AIDL))
        exec_cmd([CMD_GEN_AIDL])

    if not path.exists(CMD_AIDL):
        logger.error("Could not generate AIDL tool")
        sys.exit(1)
    else:
        logger.debug("Installed aidl at %s" %(CMD_AIDL))

    logger.debug("aidl_ops:")
    logger.debug  ("\tOperation        = %s" %(_operation))
    logger.debug  ("\tInterface Name   = %s" %(_interface_name))
    logger.verbose("\tInterfaces Roots = %s" %(_interfaces_roots))
    logger.verbose("\tOutput Directory = %s" %(_out_dir))

    if _operation == "update_api" or _operation == "freeze_api":
        handle_aidl_api()
    elif _operation == "generate_source":
        logger.verbose("\tGen Directory    = %s" %(_gen_dir))
        logger.verbose("\tGen Version      = %s" %(_gen_version))
        try:
            handle_aidl_gen_rule()
        except RuntimeError as e:
            logger.error("Source generation failed: %s" % str(e))
            sys.exit(1)
    elif _operation == "generate_deps":
        handle_aidl_gen_deps()


if __name__ == '__main__':
    main(sys.argv[1:])
