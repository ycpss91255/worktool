#!/usr/bin/env bash
# lib/commit_attribution.sh - commit and PR attribution checks (issue #271).
#
# Public API:
#   commit_attribution_check_commits <repo> <git revision>...
#       -> checks every commit selected by the revisions, listing each
#          offending SHA and attribution line on stderr. Returns 1 when any
#          line is found, otherwise 0.
#   commit_attribution_check_pr_body <event> <body>
#       -> checks <body> on pull_request events and ignores it on push.
#   commit_attribution_range <event> <pr_base> <pr_head> <push_before>
#                            <push_after> <default_ref>
#       -> prints the same fail-closed revisions as commit_email_range.
#
# This is a library: source it. It sets no shell options and prints nothing
# at source time.

_COMMIT_ATTRIBUTION_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./attribution.sh
source "${_COMMIT_ATTRIBUTION_LIB_DIR}/attribution.sh"
# shellcheck source=./log.sh
source "${_COMMIT_ATTRIBUTION_LIB_DIR}/log.sh"

_commit_attribution_is_sha() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

_commit_attribution_is_zero() {
    [[ "$1" == '0000000000000000000000000000000000000000' ]]
}

_commit_attribution_is_commit() {
    _commit_attribution_is_sha "$1" && ! _commit_attribution_is_zero "$1"
}

_commit_attribution_range_error() {
    log_error "commit_attribution_range: $1; refusing to guess a range (fail closed)."
}

commit_attribution_range() {
    if (($# != 6)); then
        _commit_attribution_range_error "expected 6 arguments, got $#"
        return 1
    fi
    local _event="$1" _base="$2" _head="$3" _before="$4" _after="$5" _default="$6"
    if [[ -z "${_default}" ]] || ! git check-ref-format "${_default}" >/dev/null 2>&1; then
        _commit_attribution_range_error "default ref '${_default}' is not a full ref name"
        return 1
    fi
    case "${_event}" in
        pull_request)
            if ! _commit_attribution_is_commit "${_base}" || ! _commit_attribution_is_commit "${_head}"; then
                _commit_attribution_range_error 'pull_request base or head is not a commit sha'
                return 1
            fi
            printf '%s\n' "${_base}..${_head}"
            ;;
        push)
            if ! _commit_attribution_is_sha "${_before}" || ! _commit_attribution_is_commit "${_after}"; then
                _commit_attribution_range_error 'push before or after is not a commit sha'
                return 1
            fi
            if _commit_attribution_is_zero "${_before}"; then
                printf '%s\n' "${_after}" "^${_default}"
            else
                printf '%s\n' "${_before}..${_after}"
            fi
            ;;
        *)
            _commit_attribution_range_error "event '${_event}' is neither pull_request nor push"
            return 1
            ;;
    esac
}

_commit_attribution_fix_commits() {
    log_info 'Fix: reword the PR branch commits, then push the rewritten branch:'
    log_info '  git rebase -i --rebase-merges origin/main'
    log_info '  git push --force-with-lease'
    log_info 'A single last commit: git commit --amend'
}

commit_attribution_check_commits() {
    local _repo="$1" _tmp _sha _message _found _line _bad=0 _n=0
    shift
    _tmp="$(mktemp)" || return 1
    if ! git -C "${_repo}" log --format='%H%x00%B%x00' "$@" -- > "${_tmp}"; then
        rm -f -- "${_tmp}"
        return 1
    fi
    while IFS= read -r -d '' _sha && IFS= read -r -d '' _message; do
        _n=$((_n + 1))
        _found="$(attribution_find "${_message}")" || continue
        while IFS= read -r _line; do
            log_error "${_sha} ${_line}"
        done <<< "${_found}"
        _bad=$((_bad + 1))
    done < "${_tmp}"
    rm -f -- "${_tmp}"
    if ((_bad > 0)); then
        log_error "${_bad} of ${_n} commits hold an attribution line."
        _commit_attribution_fix_commits
        return 1
    fi
    log_info "${_n} commits checked: no attribution line."
}

commit_attribution_check_pr_body() {
    local _event="$1" _body="$2" _found _line
    [[ "${_event}" == pull_request ]] || return 0
    _found="$(attribution_find "${_body}")" || {
        log_info 'PR body checked: no attribution line.'
        return 0
    }
    while IFS= read -r _line; do
        log_error "PR body: ${_line}"
    done <<< "${_found}"
    log_info 'Fix: edit the PR body to remove the attribution line.'
    return 1
}
