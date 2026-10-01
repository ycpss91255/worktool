#!/usr/bin/env bash
# lib/commit_refs.sh - issue footer checks (issue #312).
# Source this library; it sets no shell options and prints nothing.
# Public API: commit_refs_check_commits <repo> <git revision>...
# Diagnostics go to stderr; a rejected range or commit returns 1.

# shellcheck source-path=SCRIPTDIR
_COMMIT_REFS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./log.sh
source "${_COMMIT_REFS_LIB_DIR}/log.sh"

_commit_refs_has_footer() {
    local _message="$1" _line
    while [[ "${_message}" == *$'\n' ]]; do
        _message="${_message%$'\n'}"
    done
    _message="${_message##*$'\n\n'}"
    while IFS= read -r _line; do
        [[ "${_line}" =~ ^Refs:\ #[0-9]+$ ]] && return 0
    done <<< "${_message}"
    return 1
}

commit_refs_check_commits() {
    local _repo="$1" _tmp _sha _message _bad=0 _n=0
    shift
    _tmp="$(mktemp)" || return 1
    if ! git -C "${_repo}" log -z --format='%H%x00%B' "$@" -- > "${_tmp}"; then
        rm -f -- "${_tmp}"
        return 1
    fi
    while IFS= read -r -d '' _sha && IFS= read -r -d '' _message; do
        _n=$((_n + 1))
        _commit_refs_has_footer "${_message}" && continue
        log_error "${_sha} missing Refs: #<number> in the final paragraph."
        _bad=$((_bad + 1))
    done < "${_tmp}"
    rm -f -- "${_tmp}"
    if ((_bad > 0)); then
        log_error "${_bad} of ${_n} commits need a Refs: #<number> footer."
        return 1
    fi
    log_info "${_n} commits checked: issue footers ok."
}
