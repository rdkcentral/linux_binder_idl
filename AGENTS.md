<!--
  Copyright 2026 RDK Management

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

  SPDX-License-Identifier: Apache-2.0
-->

# Agent instructions

The project conventions for AI coding agents are in
[.github/copilot-instructions.md](.github/copilot-instructions.md). They apply to
every agent, not only Copilot. [BUILD.md](BUILD.md) is the authoritative build
guide.

## AOSP sources

- `android/` is unpacked from the AOSP source tarball by `./aosp-source.sh` and
  patched with `patches/*.patch`. Never edit it, and never clone AOSP into it.
- `aosp/manifest` defines the tarball; `aosp/aosp-source.sha256` identifies it.
  Change them only together, with `./aosp-source.sh generate --update`.
- The SDK publishes no tarball. Each team generates it, uploads it to its own
  artifact store (e.g. Artifactory) and sets `AOSP_SOURCE_URI`. The
  `AOSP_SOURCE_URI` in `example/yocto/linux-binder.bb` is a placeholder on a
  `.invalid` host and stays one; never commit the tarball or a real location.
- To change AOSP code, edit a patch and run `./aosp-source.sh unpack`.
