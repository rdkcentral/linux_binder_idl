#/**
# * Copyright 2026 RDK Management
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
#
# binder_install_runpath()
#
# Records the install prefix's library directory in every installed artifact as
# DT_RUNPATH, so a build installed outside the loader's default search path
# resolves its own dependencies.
#
# This is what lets the middleware and the vendor layer each install this
# library to a prefix of their own -- /mw/usr and /vendor/usr, say -- and have
# each layer's binaries load the copy belonging to that layer. Without it the
# library is found by SONAME through the default search path, and two prefixes
# resolve to whichever copy that path happens to reach, or to none.
#
# RUNPATH goes on every artifact rather than only the executables, because
# DT_RUNPATH is not inherited transitively: a service carrying
# RUNPATH=/mw/usr/lib links libbinder.so, but that entry does not help
# libbinder.so find liblog, libbase, libcutils or libutils in the same prefix.
# Each library needs its own. DT_RPATH is inherited, but LD_LIBRARY_PATH
# overrides it, which with two copies of the library present is worse than the
# problem it solves -- hence new dtags.
#
# Call once, before any add_library() or add_executable(), and after project():
# CMAKE_INSTALL_RPATH is read at target creation, and the compiler identity is
# needed to select the linker flag. Repeat calls are no-ops, so a file that is
# both included and used standalone may call it unconditionally.
#
# Variables read:
#   CMAKE_INSTALL_LIBDIR     the prefix's library directory (the RUNPATH value)
#   BINDER_INSTALL_RUNPATH   ON (default) to emit RUNPATH, OFF to suppress it
#
# Variables set, in the caller's directory scope:
#   CMAKE_INSTALL_RPATH, CMAKE_INSTALL_RPATH_USE_LINK_PATH,
#   CMAKE_BUILD_WITH_INSTALL_RPATH, CMAKE_SKIP_INSTALL_RPATH,
#   and --enable-new-dtags appended to the shared and executable linker flags.

macro(binder_install_runpath)
    if (DEFINED _BINDER_RUNPATH_APPLIED)
        # Already applied in this scope, or inherited from the includer.
    else ()
        set(_BINDER_RUNPATH_APPLIED TRUE)

        if (NOT DEFINED BINDER_INSTALL_RUNPATH)
            set(BINDER_INSTALL_RUNPATH ON)
        endif ()

        # A prefix already on the loader's default search path needs no RUNPATH,
        # and emitting one there is what Yocto's `useless-rpaths` QA check
        # rejects. So a stock prefix keeps the behaviour it has always had, and
        # only a prefix chosen to separate one layer from another gets a RUNPATH.
        set(_binder_loader_default_libdirs
            /lib /lib32 /lib64
            /usr/lib /usr/lib32 /usr/lib64
            /usr/local/lib /usr/local/lib32 /usr/local/lib64
        )

        if (NOT BINDER_INSTALL_RUNPATH)
            message("install RUNPATH: disabled (BINDER_INSTALL_RUNPATH=OFF)")
        elseif (NOT DEFINED CMAKE_INSTALL_LIBDIR)
            message(WARNING
                "BINDER_INSTALL_RUNPATH is ON but CMAKE_INSTALL_LIBDIR is not "
                "set, so there is no prefix to record. Set CMAKE_INSTALL_LIBDIR "
                "(or CMAKE_INSTALL_PREFIX) before calling binder_install_runpath().")
        elseif ("${CMAKE_INSTALL_LIBDIR}" IN_LIST _binder_loader_default_libdirs)
            message("install RUNPATH: not needed — ${CMAKE_INSTALL_LIBDIR} is on "
                    "the loader's default search path")
        else ()
            set(CMAKE_INSTALL_RPATH "${CMAKE_INSTALL_LIBDIR}")

            # Record only the prefix. The link line's directories belong to the
            # build tree and must not reach the installed artifact.
            set(CMAKE_INSTALL_RPATH_USE_LINK_PATH OFF)

            # Keep the build tree's own RPATH while building, so tests run
            # against what was just built; CMake re-links to the install RPATH
            # at install time.
            set(CMAKE_BUILD_WITH_INSTALL_RPATH OFF)
            set(CMAKE_SKIP_INSTALL_RPATH OFF)

            # DT_RUNPATH rather than DT_RPATH. GNU ld has defaulted to new dtags
            # for long enough that this is usually already the case, but the
            # default is a toolchain build option, and which tag is emitted
            # decides whether LD_LIBRARY_PATH can override the prefix. lld emits
            # RUNPATH only and needs no flag.
            if (CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
                foreach (_binder_flags_var
                         CMAKE_SHARED_LINKER_FLAGS
                         CMAKE_EXE_LINKER_FLAGS)
                    string(FIND "${${_binder_flags_var}}" "--enable-new-dtags"
                           _binder_dtags_pos)
                    if (_binder_dtags_pos EQUAL -1)
                        set(${_binder_flags_var}
                            "${${_binder_flags_var}} -Wl,--enable-new-dtags")
                    endif ()
                endforeach ()
            endif ()

            message("install RUNPATH: ${CMAKE_INSTALL_RPATH}")
        endif ()
    endif ()
endmacro()
