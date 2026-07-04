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
# Thin wrapper so tests/run-tests.sh (which auto-discovers tests/test_*.sh)
# picks up the optional QEMU binder round-trip test. The real harness lives at
# tests/qemu/run-qemu-test.sh; it skips cleanly when QEMU/busybox/a compiler or
# built kernels are absent, so it never breaks a default suite run.
exec "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/qemu/run-qemu-test.sh" "$@"
