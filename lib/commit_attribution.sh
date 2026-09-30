#!/usr/bin/env bash
# lib/commit_attribution.sh - commit and PR attribution checks (issue #271).
#
# Public API:
#   commit_attribution_check_commits <repo> <git revision>...
#       -> checks every commit selected by the revisions, listing each
#          offending SHA and attribution line on stderr. Returns 1 when any
#          line is found, otherwise 0.
#
# This is a library: source it. It sets no shell options and prints nothing
# at source time.

_COMMIT_ATTRIBUTION_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./attribution.sh
source "${_COMMIT_ATTRIBUTION_LIB_DIR}/attribution.sh"
# shellcheck source=./log.sh
source "${_COMMIT_ATTRIBUTION_LIB_DIR}/log.sh"

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
