#!/usr/bin/env bash
# lib/apt_cache.sh - the box package dir CI persists between runs (issue #847).
# Source this library; it sets no shell options and prints only its results.
#
# CI keeps the .deb files the real-engine box's first launch downloads
# (script/test/apt-mirror.sh --archives) in an actions/cache entry, so the
# next run's full install only fetches what changed. apt itself checks
# every cached file against the index (version and hash), so a stale file
# costs a download, never a wrong install.
#
# Public API:
#   apt_cache_prune <dir>
#       -> deletes every <dir>/*.deb but the newest version of each
#          package and architecture (Debian file names
#          <name>_<version>_<arch>.deb, version with `%3a` for the epoch
#          colon; an absent epoch counts as 0, versions compared with
#          `sort -V`), so the dir does not grow with every update. Other
#          files are left alone. Returns 1 when <dir> is not a directory.
#   apt_cache_key <dir>
#       -> prints "<16 hex> <count>": a digest of the sorted *.deb names and
#          their number, so an unchanged set maps to the same cache key.

# shellcheck source-path=SCRIPTDIR
_APT_CACHE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./log.sh
source "${_APT_CACHE_LIB_DIR}/log.sh"

apt_cache_prune() {
    local _dir="${1:-}" _f _b _name _rest _ver _arch
    if [[ ! -d "${_dir}" ]]; then
        log_error "apt_cache_prune: not a directory: '${_dir}'"
        return 1
    fi
    for _f in "${_dir}"/*.deb; do
        [[ -f "${_f}" ]] || continue
        _b="${_f##*/}"
        _name="${_b%%_*}"
        _rest="${_b#*_}"
        _ver="${_rest%_*}"
        _arch="${_rest##*_}"
        _ver="${_ver//%3a/:}"
        [[ "${_ver}" == *:* ]] || _ver="0:${_ver}"
        printf '%s_%s\t%s\t%s\n' "${_name}" "${_arch%.deb}" "${_ver}" "${_b}"
    done | LC_ALL=C sort -t $'\t' -k1,1 -k2,2V \
        | awk -F '\t' '{ if (NR > 1 && $1 == key) print prev; key = $1; prev = $3 }' \
        | while IFS= read -r _b; do
            rm -f -- "${_dir:?}/${_b}"
        done
}

apt_cache_key() {
    local _dir="${1:-}" _names _n _sum
    _names="$(cd -- "${_dir}" && find . -maxdepth 1 -type f -name '*.deb' | sed 's|^\./||' | LC_ALL=C sort)" \
        || return 1
    _n=0
    [[ -z "${_names}" ]] || _n="$(grep -c . <<<"${_names}")"
    _sum="$(sha256sum <<<"${_names}")" || return 1
    printf '%s %s\n' "${_sum:0:16}" "${_n}"
}
