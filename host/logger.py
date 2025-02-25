#!/usr/bin/env python3

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
        match level:
            case self.FATAL:
                self._print(Fore.RED, level, msg)
                #TODO kill the execution
                return
            case self.ERROR:
                self._print(Fore.RED, level, msg)
                return
            case self.WARNING:
                self._print(Fore.YELLOW, level, msg)
                return
            case self.INFO | self.DEBUG | self.VERBOSE:
                self._print(Fore.BLACK, level, msg)
                return
            case _:
                self._print(Fore.BLACK, self.VERBOSE, msg)
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


