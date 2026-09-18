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
# Each library needs its own.
#
# The glibc search order is DT_RPATH (only when DT_RUNPATH is absent), then
# LD_LIBRARY_PATH, then DT_RUNPATH, then the cache and the default directories.
# The two tags therefore differ in both respects, and in opposite directions:
# DT_RPATH is inherited by dependency lookups and outranks LD_LIBRARY_PATH,
# while DT_RUNPATH is neither.
#
# New dtags are chosen anyway. DT_RPATH is deprecated, and OpenEmbedded's
# tooling normalises to DT_RUNPATH, so emitting the deprecated tag fights the
# platform rather than the problem. Its transitivity buys nothing here because
# every artifact is given its own entry, which is what makes the prefix hold
# through a dependency chain. The cost it does carry is real and belongs in the
# layout's rules: LD_LIBRARY_PATH takes precedence over DT_RUNPATH, so pointing
# it at another layer's prefix defeats the separation. See BUILD.md.
#
# Call once, before any add_library() or add_executable(), and after project():
# CMAKE_INSTALL_RPATH is read at target creation, and the compiler identity is
# needed to select the linker flag. Repeat calls are no-ops, so a file that is
# both included and used standalone may call it unconditionally.
#
# CMAKE_INSTALL_LIBDIR may be given relative to the prefix -- that is what
# GNUInstallDirs produces and what OpenEmbedded's cmake.bbclass passes -- so it
# is resolved against CMAKE_INSTALL_PREFIX before being compared or recorded. A
# relative value reaching DT_RUNPATH would be resolved by the loader against the
# process's working directory rather than the prefix.
#
# Variables read:
#   CMAKE_INSTALL_LIBDIR     the prefix's library directory, absolute or
#                            relative to CMAKE_INSTALL_PREFIX (the RUNPATH value)
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

        # Resolve a prefix-relative libdir, so the comparison below sees the
        # same form as the list and a relative value never reaches DT_RUNPATH.
        if (DEFINED CMAKE_INSTALL_LIBDIR)
            if (IS_ABSOLUTE "${CMAKE_INSTALL_LIBDIR}")
                set(_binder_libdir "${CMAKE_INSTALL_LIBDIR}")
            else ()
                set(_binder_libdir "${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}")
            endif ()
        endif ()

        if (NOT BINDER_INSTALL_RUNPATH)
            message("install RUNPATH: disabled (BINDER_INSTALL_RUNPATH=OFF)")
        elseif (NOT DEFINED CMAKE_INSTALL_LIBDIR)
            message(WARNING
                "BINDER_INSTALL_RUNPATH is ON but CMAKE_INSTALL_LIBDIR is not "
                "set, so there is no prefix to record. Set CMAKE_INSTALL_LIBDIR "
                "(or CMAKE_INSTALL_PREFIX) before calling binder_install_runpath().")
        elseif ("${_binder_libdir}" IN_LIST _binder_loader_default_libdirs)
            message("install RUNPATH: not needed — ${_binder_libdir} is on "
                    "the loader's default search path")
        else ()
            set(CMAKE_INSTALL_RPATH "${_binder_libdir}")

            # Record only the prefix. The link line's directories belong to the
            # build tree and must not reach the installed artifact.
            set(CMAKE_INSTALL_RPATH_USE_LINK_PATH OFF)

            # Keep the build tree's own RPATH while building, so tests run
            # against what was just built; CMake re-links to the install RPATH
            # at install time.
            set(CMAKE_BUILD_WITH_INSTALL_RPATH OFF)
            set(CMAKE_SKIP_INSTALL_RPATH OFF)

            # DT_RUNPATH rather than DT_RPATH, for the reasons in the header
            # comment. GNU ld has defaulted to new dtags for long enough that
            # this is usually already the case, but the default is a toolchain
            # build option, so which tag is emitted is not something to assume.
            # lld emits DT_RUNPATH only and needs no flag.
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
