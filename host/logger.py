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

import inspect
from datetime import datetime
from colorama import Fore

LOGLEVEL_TO_STR = [
        "FATAL",
        "ERROR",
        "WARNING",
        "INFO",
        "DEBUG",
        "VERBOSE"
        ]

# date&time [logLevel]  [logTag] function():line msg....
_LOG_BLUEPRINT = "%s\t[%-8s] %s  %s():%s %s"

class Logger:
    FATAL   = 0
    ERROR   = 1
    WARNING = 2
    INFO    = 3
    DEBUG   = 4
    VERBOSE = 5

    _log_tag = "default"
    _log_level = INFO

    def __init__(self, log_tag=None, log_level=None):
        if log_tag is not None:
            self._log_tag = log_tag

        if log_level is not None:
            self._log_level = log_level

    def fatal(self, msg):
        self._log(self.FATAL, msg)

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
        if level == self.FATAL:
            self._print(Fore.RED, level, msg)
            assert False, "%s" %(msg)
            #TODO kill the execution
            return
        elif level == self.ERROR:
            self._print(Fore.RED, level, msg)
            return
        elif level == self.WARNING:
            self._print(Fore.YELLOW, level, msg)
            return
        elif level == self.INFO or level == self.DEBUG or level == self.VERBOSE:
            # Use Fore.RESET to use the user's terminal default (usually white/grey)
            self._print(Fore.RESET, level, msg) 
            return
        else:
            self._print(Fore.RESET, self.VERBOSE, msg)
            return

    def _print(self, fore, level, msg):
        if (level <= self._log_level):
            print(fore + _LOG_BLUEPRINT %
                    (datetime.today().strftime('%Y-%m-%d %H:%M:%S'),
                        LOGLEVEL_TO_STR[level], self._log_tag,
                        inspect.stack()[3].function, inspect.stack()[3].lineno, msg))

def test_logs():
    logger = Logger("test_tag", Logger.VERBOSE)
    logger.verbose("This is a VERBOSE type log with VERBOSE logging level")
    logger.debug("This is a DEBUG type log with VERBOSE logging level")
    logger.info("This is an INFO type log with VERBOSE logging level")
    logger.warning("This is an WARNING type log with VERBOSE logging level")
    logger.error("This is an ERROR type log with VERBOSE logging level")
    logger.fatal("This is a FATAL type log with VERBOSE logging level")

    logger = Logger("test_tag", Logger.INFO)
    logger.verbose("This is a VERBOSE type log with INFO logging level")
    logger.debug("This is a DEBUG type log with INFO logging level")
    logger.info("This is an INFO type log with INFO logging level")
    logger.warning("This is an WARNING type log with INFO logging level")
    logger.error("This is an ERROR type log with INFO logging level")
    logger.fatal("This is a FATAL type log with INFO logging level")

if __name__ == '__main__':
    test_logs()


