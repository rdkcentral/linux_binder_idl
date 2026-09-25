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
# aosp-source.sh - the AOSP sources the Binder SDK builds against.
#
# The sources come from ONE tarball, used unchanged by Yocto and standalone
# builds. aosp/manifest defines it exactly: the repositories, the commit of
# each, and the paths taken. The same manifest always produces a byte-identical
# tarball, whose sha256 is committed in aosp/aosp-source.sha256.
#
# The SDK publishes no tarball. Each team generates it once, uploads it to its
# own artifact store (e.g. Artifactory), and points builds at it with
# AOSP_SOURCE_URI. The sha256 is the tarball's identity wherever it is hosted.
#
# The tarball holds unpatched upstream source. patches/<dir>.patch is applied
# on top at build time, so changing a patch never needs a new tarball.
#
# Run ./aosp-source.sh help for the commands.

set -euo pipefail

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The AOSP_MANIFEST / AOSP_SHA_FILE / AOSP_PATCH_DIR overrides exist for
# tests/test_aosp_source.sh; a build uses the files in this repository.
MANIFEST="${AOSP_MANIFEST:-${ROOT}/aosp/manifest}"
SHA_FILE="${AOSP_SHA_FILE:-${ROOT}/aosp/aosp-source.sha256}"
PATCH_DIR="${AOSP_PATCH_DIR:-${ROOT}/patches}"
ANDROID_DIR="${ANDROID_DIR:-${ROOT}/android}"
AOSP_SOURCE_CACHE="${AOSP_SOURCE_CACHE:-${ROOT}/downloads}"
AOSP_SOURCE_URI="${AOSP_SOURCE_URI:-}"

# Fixed archive metadata. Every file gets this mtime, owner 0/0 and a mode
# normalised to u+rw,go+r (plus x where the source had it), so the tarball
# depends on the manifest alone - not on the machine, user or umask that ran it.
TAR_MTIME="@946684800"   # 2000-01-01T00:00:00Z
STAMP=".aosp-source"     # written into ANDROID_DIR: tarball sha256 + patch set sha256

die()  { echo "aosp-source: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
    cat <<EOF
Usage: ./aosp-source.sh <command> [options]

Commands:
  provision             Make android/ ready to build: unpacked from the tarball,
                        with the current patches applied. Does nothing when it
                        already is. The build wrappers run this.
  unpack [TARBALL]      Replace android/ with a fresh copy of the tarball and
                        apply patches/. Run it after changing a patch.
  apply-patches [--android-dir DIR]
                        Apply patches/*.patch to an unpacked tree. The Yocto
                        recipe runs this from do_patch.
  generate [--update]   Build the tarball from aosp/manifest into the cache and
                        check it against aosp/aosp-source.sha256. --update
                        rewrites that file instead, when the manifest changed.
  name                  Print the tarball's file name.
  sha256                Print the tarball's expected sha256.
  help                  This text.

Where the tarball comes from, in order:
  1. TARBALL, when given to unpack
  2. the cache:           \${AOSP_SOURCE_CACHE:-downloads}/<name>
  3. AOSP_SOURCE_URI:     your team's hosted copy (https://, file:// or a path)
  4. provision only:      generated locally from the AOSP repositories

The SDK publishes no tarball. To host one: ./aosp-source.sh generate, upload
downloads/<name> to your team's artifact store, and set AOSP_SOURCE_URI to it.
EOF
}

# --- manifest ---------------------------------------------------------------

manifest_lines() { grep -vE '^[[:space:]]*(#|$)' "${MANIFEST}"; }

manifest_tag() {
    manifest_lines | awk '$1 == "tag" { print $2; exit }'
}

# The name carries the tag for people and a hash of the manifest for tools, so
# a changed manifest can never be served from a cache under the old name.
tarball_name() {
    local tag digest
    tag="$(manifest_tag)"
    [ -n "${tag}" ] || die "no 'tag' line in ${MANIFEST}"
    digest="$(manifest_lines | sed 's/[[:space:]]\+/ /g' | sha256sum | cut -c1-8)"
    echo "aosp-${tag}-src-${digest}.tar.gz"
}

expected_sha256() {
    [ -f "${SHA_FILE}" ] || die "${SHA_FILE} is missing"
    local sha file
    read -r sha file < "${SHA_FILE}"
    [ "${file}" = "$(tarball_name)" ] \
        || die "${SHA_FILE} names ${file}, but aosp/manifest describes $(tarball_name) - run ./aosp-source.sh generate --update"
    echo "${sha}"
}

patchset_sha256() {
    # The set of patches, by name and content, in the order they are applied.
    local p
    for p in "${PATCH_DIR}"/*.patch; do
        [ -e "${p}" ] || continue
        printf '%s ' "$(basename "${p}")"
        sha256sum < "${p}" | cut -d' ' -f1
    done | sha256sum | cut -d' ' -f1
}

# --- tarball ----------------------------------------------------------------

verify() {
    local file="$1" want got
    want="$(expected_sha256)"
    got="$(sha256sum "${file}" | cut -d' ' -f1)"
    [ "${got}" = "${want}" ] \
        || die "${file} has sha256 ${got}; aosp/aosp-source.sha256 expects ${want}"
}

fetch() {
    local dest="$1" uri="${AOSP_SOURCE_URI}"
    [ -n "${uri}" ] || return 1
    mkdir -p "$(dirname "${dest}")"
    case "${uri}" in
        file://*) cp "${uri#file://}" "${dest}.part" ;;
        *://*)    info "Downloading ${uri}"
                  curl -fL --retry 3 -o "${dest}.part" "${uri}" ;;
        *)        cp "${uri}" "${dest}.part" ;;
    esac
    mv "${dest}.part" "${dest}"
}

# Prints the path of a verified tarball, or fails.
locate() {
    local given="${1:-}" cached
    if [ -n "${given}" ]; then
        verify "${given}"; echo "${given}"; return
    fi
    cached="${AOSP_SOURCE_CACHE}/$(tarball_name)"
    if [ ! -f "${cached}" ] && ! fetch "${cached}"; then
        return 1
    fi
    verify "${cached}"
    echo "${cached}"
}

cmd_generate() {
    local update=0
    [ "${1:-}" = "--update" ] && update=1

    need git tar gzip
    tar --sort=name --version >/dev/null 2>&1 || die "generate needs GNU tar 1.28 or later (--sort)"

    local name work out
    name="$(tarball_name)"
    work="$(mktemp -d "${TMPDIR:-/tmp}/aosp-source.XXXXXX")"
    GENERATE_WORK="${work}"
    trap 'rm -rf "${GENERATE_WORK}"' EXIT
    mkdir -p "${work}/android" "${AOSP_SOURCE_CACHE}"

    local dir url commit paths got
    while read -r dir url commit paths; do
        [ "${dir}" = "tag" ] && continue
        info "${dir}: ${commit}"
        git init -q "${work}/repo-${dir}"
        git -C "${work}/repo-${dir}" fetch -q --depth 1 "${url}" "${commit}"
        got="$(git -C "${work}/repo-${dir}" rev-parse FETCH_HEAD)"
        [ "${got}" = "${commit}" ] || die "${url} served ${got} for ${commit}"
        mkdir -p "${work}/android/${dir}"
        # shellcheck disable=SC2086  # paths is a word list by design
        git -C "${work}/repo-${dir}" archive --format=tar "${commit}" ${paths:+-- ${paths}} \
            | tar -x -C "${work}/android/${dir}"
        rm -rf "${work}/repo-${dir}"
    done < <(manifest_lines)

    out="${AOSP_SOURCE_CACHE}/${name}"
    tar --sort=name --format=gnu --mtime="${TAR_MTIME}" \
        --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' \
        -C "${work}" -cf - android | gzip -9 -n > "${out}.part"
    mv "${out}.part" "${out}"

    local sha
    sha="$(sha256sum "${out}" | cut -d' ' -f1)"
    info "Wrote ${out}"
    echo "    sha256 ${sha}"

    if [ "${update}" -eq 1 ]; then
        echo "${sha}  ${name}" > "${SHA_FILE}"
        info "Updated aosp/aosp-source.sha256 - commit it with aosp/manifest"
    else
        verify "${out}"
        info "Matches aosp/aosp-source.sha256. Upload ${name} to your team's artifact store."
    fi
}

cmd_apply_patches() {
    local dir="${ANDROID_DIR}"
    if [ "${1:-}" = "--android-dir" ]; then
        [ -n "${2:-}" ] || die "--android-dir needs a directory"
        dir="$2"
    fi
    [ -d "${dir}" ] || die "${dir} does not exist - unpack the tarball first"

    # A tree with no stamp is taken as fresh from the tarball: that is what
    # BitBake's do_unpack leaves. One stamped with another patch set is not.
    local want applied=""
    want="$(patchset_sha256)"
    [ -f "${dir}/${STAMP}" ] && applied="$(sed -n 's/^patches //p' "${dir}/${STAMP}")"
    if [ "${applied}" = "${want}" ]; then
        info "Patches already applied"
        return
    fi
    [ -z "${applied}" ] \
        || die "${dir} carries a different patch set - run ./aosp-source.sh unpack to start from the tarball"

    local p target
    for p in "${PATCH_DIR}"/*.patch; do
        [ -e "${p}" ] || continue
        target="${dir}/$(basename "${p}" .patch)"
        [ -d "${target}" ] || die "$(basename "${p}") has no tree ${target}"
        info "Applying $(basename "${p}")"
        patch -p1 --batch --forward --fuzz=0 --no-backup-if-mismatch -s -d "${target}" < "${p}" \
            || die "$(basename "${p}") does not apply to ${target}"
    done
    echo "patches ${want}" >> "${dir}/${STAMP}"
}

cmd_unpack() {
    local tarball
    tarball="$(locate "${1:-}")" || die "no tarball: pass one, put $(tarball_name) in ${AOSP_SOURCE_CACHE}, or set AOSP_SOURCE_URI"
    need tar gzip patch
    info "Unpacking $(basename "${tarball}") into ${ANDROID_DIR}"
    rm -rf "${ANDROID_DIR}"
    mkdir -p "${ANDROID_DIR}"
    tar -xzf "${tarball}" -C "${ANDROID_DIR}" --strip-components=1
    echo "tarball $(expected_sha256)" > "${ANDROID_DIR}/${STAMP}"
    cmd_apply_patches --android-dir "${ANDROID_DIR}"
}

cmd_provision() {
    local stamp="${ANDROID_DIR}/${STAMP}"
    if [ -f "${stamp}" ] \
       && grep -qx "tarball $(expected_sha256)" "${stamp}" \
       && grep -qx "patches $(patchset_sha256)" "${stamp}"; then
        info "android/ is current"
        return
    fi
    [ -d "${ANDROID_DIR}" ] && info "android/ is out of date or was not unpacked from the tarball; replacing it"

    if ! locate >/dev/null 2>&1; then
        info "No tarball in ${AOSP_SOURCE_CACHE} and no AOSP_SOURCE_URI; generating it from aosp/manifest"
        cmd_generate
    fi
    cmd_unpack
}

need() {
    local tool
    for tool in "$@"; do
        command -v "${tool}" >/dev/null 2>&1 || die "${tool} not found on PATH"
    done
}
case "${1:-help}" in
    help|-h|--help) ;;
    *) need sha256sum sed cut ;;
esac

case "${1:-help}" in
    provision)      shift; cmd_provision "$@" ;;
    unpack)         shift; cmd_unpack "$@" ;;
    apply-patches)  shift; cmd_apply_patches "$@" ;;
    generate)       shift; cmd_generate "$@" ;;
    name)           tarball_name ;;
    sha256)         expected_sha256 ;;
    help|-h|--help) usage ;;
    *)              usage >&2; exit 2 ;;
esac
