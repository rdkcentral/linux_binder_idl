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

# Logging for the host toolchain, on the standard library alone, and on Python
# 3.6 or later: no third-party package and no stdlib feature newer than 3.6.
#
# Records go to stderr as
#     date time [LEVEL   ] tag  function():line message
# coloured only when stderr is a terminal (and NO_COLOR is unset), so redirected
# build logs carry no escape sequences. fatal() logs and exits with status 1.

import logging
import os
import sys

_FORMAT = "%(asctime)s\t[%(levelname)-8s] %(name)s  %(caller_func)s():%(caller_line)d %(message)s"
_DATE_FORMAT = "%Y-%m-%d %H:%M:%S"

_RED = "\033[31m"
_YELLOW = "\033[33m"
_RESET = "\033[0m"


class Logger:
    FATAL   = 0
    ERROR   = 1
    WARNING = 2
    INFO    = 3
    DEBUG   = 4
    VERBOSE = 5

    # Logger level -> (stdlib level, printed name, colour)
    _LEVELS = {
        FATAL:   (logging.CRITICAL, "FATAL",   _RED),
        ERROR:   (logging.ERROR,    "ERROR",   _RED),
        WARNING: (logging.WARNING,  "WARNING", _YELLOW),
        INFO:    (logging.INFO,     "INFO",    None),
        DEBUG:   (logging.DEBUG,    "DEBUG",   None),
        VERBOSE: (5,                "VERBOSE", None),
    }

    def __init__(self, log_tag=None, log_level=None):
        self._log_level = self.INFO if log_level is None else log_level
        # A standalone stdlib logger per instance, never one from
        # logging.getLogger(): that registry is process-wide, and getLogger("")
        # is the root logger - configuring it would change logging for the
        # whole process. Filtering is done here, by _log_level.
        self._logger = logging.Logger("default" if log_tag is None else log_tag, 1)
        handler = logging.StreamHandler(sys.stderr)
        colour = sys.stderr.isatty() and "NO_COLOR" not in os.environ
        handler.setFormatter(_Formatter(colour))
        self._logger.addHandler(handler)

    def fatal(self, msg):
        self._log(self.FATAL, msg)
        sys.exit(1)

    def error(self, msg):
        self._log(self.ERROR, msg)

    def warning(self, msg):
        self._log(self.WARNING, msg)

    def info(self, msg):
        self._log(self.INFO, msg)

    def debug(self, msg):
        self._log(self.DEBUG, msg)

    def verbose(self, msg):
        self._log(self.VERBOSE, msg)

    def _log(self, level, msg):
        if level > self._log_level:
            return
        stdlib_level, name, colour = self._LEVELS.get(level, self._LEVELS[self.VERBOSE])
        # The caller of fatal()/error()/...: two frames up from here. Passed as
        # extra fields, since logging's own stacklevel needs Python 3.8.
        caller = sys._getframe(2)
        self._logger.log(stdlib_level, msg,
                         extra={"logger_name": name, "logger_colour": colour,
                                "caller_func": caller.f_code.co_name,
                                "caller_line": caller.f_lineno})


class _Formatter(logging.Formatter):
    def __init__(self, colour):
        super(_Formatter, self).__init__(_FORMAT, _DATE_FORMAT)
        self._colour = colour

    def format(self, record):
        record.levelname = getattr(record, "logger_name", record.levelname)
        line = super().format(record)
        colour = getattr(record, "logger_colour", None)
        if self._colour and colour:
            return colour + line + _RESET
        return line


if __name__ == '__main__':
    demo = Logger("demo", Logger.VERBOSE)
    demo.verbose("a VERBOSE line")
    demo.debug("a DEBUG line")
    demo.info("an INFO line")
    demo.warning("a WARNING line")
    demo.error("an ERROR line")
    demo.fatal("a FATAL line - exits with status 1")
