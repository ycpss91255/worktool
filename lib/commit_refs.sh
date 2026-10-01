#!/usr/bin/env bash
# lib/commit_refs.sh - issue footer checks (issue #312).
# Source this library; it sets no shell options and prints nothing.
# Public API:
#   commit_refs_check_commits <repo> <git revision>...
#       -> require a numeric Refs line in the final message paragraph;
#          merge commits and noreply@github.com committers are exempt.
#   commit_refs_range <event> <pr_base> <pr_head> <push_before>
#                     <push_after> <default_ref>
#       -> the same fail-closed revisions as commit_email_range.
# Diagnostics go to stderr; a rejected range or commit returns 1.

# shellcheck source-path=SCRIPTDIR
_COMMIT_REFS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./log.sh
source "${_COMMIT_REFS_LIB_DIR}/log.sh"
# shellcheck source=./commit_email.sh
source "${_COMMIT_REFS_LIB_DIR}/commit_email.sh"

commit_refs_range() {
    commit_email_range "$@"
}

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
    local _repo="$1" _tmp _sha _committer _message _enforcing _bad=0 _n=0 _rc
    shift
    _enforcing="$(git -C "${_repo}" log --format=%H --reverse --diff-filter=A -- lib/commit_refs.sh)" || return 1
    _enforcing="${_enforcing%%$'\n'*}"
    if [[ -z "${_enforcing}" ]]; then
        log_error 'Cannot find enforcing commit for lib/commit_refs.sh; fetch full history (fail closed).'
        return 1
    fi
    _tmp="$(mktemp)" || return 1
    if ! git -C "${_repo}" log --no-merges -z --format='%H%x00%ce%x00%B' "$@" -- > "${_tmp}"; then
        rm -f -- "${_tmp}"
        return 1
    fi
    while IFS= read -r -d '' _sha && IFS= read -r -d '' _committer && IFS= read -r -d '' _message; do
        _rc=0
        git -C "${_repo}" merge-base --is-ancestor "${_enforcing}" "${_sha}" || _rc=$?
        if ((_rc == 1)); then
            log_info "${_sha} skipped: does not descend from enforcing commit ${_enforcing}."
            continue
        elif ((_rc != 0)); then
            rm -f -- "${_tmp}"
            log_error "Cannot establish ancestry for ${_sha} (fail closed)."
            return 1
        fi
        _n=$((_n + 1))
        [[ "${_committer}" == 'noreply@github.com' ]] && continue
        _commit_refs_has_footer "${_message}" && continue
        log_error "${_sha} missing Refs: #<number> in the final paragraph."
        _bad=$((_bad + 1))
    done < "${_tmp}"
    rm -f -- "${_tmp}"
    if ((_bad > 0)); then
        log_error "${_bad} of ${_n} commits need a Refs: #<number> footer."
        return 1
    fi
    log_info "${_n} commits checked: issue footers ok. (enforcing commit ${_enforcing})"
}
