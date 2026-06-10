#!/usr/bin/env bash

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
# Stub m4 that simulates an old Yocto SDK m4 (< 1.4.12) which lacks
# the --gnu option that bison 3.x requires. Reproduces the failure
# mode from issue #30:
#
#   m4: unrecognized option '--gnu'
#
# All other invocations delegate to the real /usr/bin/m4.

for arg in "$@"; do
  if [ "$arg" = "--gnu" ]; then
    echo "m4: unrecognized option '--gnu'" >&2
    echo "Try 'm4 --help' for more information." >&2
    exit 1
  fi
done

exec /usr/bin/m4 "$@"
