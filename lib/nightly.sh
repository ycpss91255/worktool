#!/usr/bin/env bash
# lib/nightly.sh - when the nightly full serial run runs, and what it
# reports (issue #836). Source this library; it sets no shell options and
# prints only its decisions on stdout (reasons on stderr).
#
# An open issue labelled `nightly-failure` means the last failure is not
# resolved yet. Maintainer rule (#836): a scheduled run then does not run
# again - no new issue, no new comment, so nothing is duplicated. A manual
# (workflow_dispatch) run always runs, so a fix can be verified. When the
# open issues cannot be listed, the run goes ahead: a broken check never
# silently skips the suite.
#
# Public API:
#   nightly_decide <event> <list_rc> <open issue numbers, newline separated>
#       -> prints `run`, or `skip <n>` (n = the oldest open issue) for a
#          schedule event while such an issue is open. list_rc != 0 means
#          the listing failed: run.
#   nightly_report <result> <list_rc> <open issue numbers>
#       <result> is the full serial run's result (success, or anything
#       else = failed).
#       -> prints `open` (failed, no open issue: open exactly one),
#          `comment <n>` (an open issue exists: put the run link on it,
#          green or red), or `none` (green, nothing open). A failed listing
#          on a failed run prints `open` (a possible duplicate beats a
#          silent failure); on a green run it prints `none`.

# shellcheck source-path=SCRIPTDIR
_NIGHTLY_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./log.sh
source "${_NIGHTLY_LIB_DIR}/log.sh"

NIGHTLY_LABEL=nightly-failure

# Print the oldest (smallest) issue number of the list $1, or nothing.
_nightly_oldest() {
    grep -E '^[1-9][0-9]*$' <<<"$1" | sort -n | head -n 1
}

nightly_decide() {
    local _event="$1" _rc="$2" _open _n
    if [[ "${_event}" != schedule ]]; then
        log_info "nightly: ${_event} run: always runs"
        printf 'run\n'
        return 0
    fi
    if [[ "${_rc}" != 0 ]]; then
        log_warn "nightly: could not list open ${NIGHTLY_LABEL} issues (rc ${_rc}): running anyway"
        printf 'run\n'
        return 0
    fi
    _open="${3:-}"
    _n="$(_nightly_oldest "${_open}")"
    if [[ -n "${_n}" ]]; then
        log_info "nightly: open ${NIGHTLY_LABEL} issue #${_n} is not resolved yet: skipping this scheduled run"
        printf 'skip %s\n' "${_n}"
        return 0
    fi
    printf 'run\n'
}

nightly_report() {
    local _result="$1" _rc="$2" _n=''
    if [[ "${_rc}" == 0 ]]; then
        _n="$(_nightly_oldest "${3:-}")"
    else
        log_warn "nightly: could not list open ${NIGHTLY_LABEL} issues (rc ${_rc})"
    fi
    if [[ -n "${_n}" ]]; then
        printf 'comment %s\n' "${_n}"
    elif [[ "${_result}" == success ]]; then
        printf 'none\n'
    else
        printf 'open\n'
    fi
}

# nightly_check_sha <input> - the workflow_dispatch `sha` input (issue
# #837): empty (run the dispatched ref) or a full 40-hex commit. Anything
# else prints why on stderr and returns 2, so a typo never runs (and
# reports) a different commit than the one asked for.
nightly_check_sha() {
    if [[ -z "$1" || "$1" =~ ^[0-9a-f]{40}$ ]]; then
        return 0
    fi
    log_error "nightly: sha input must be a full 40-hex commit, got '$1'"
    return 2
}
