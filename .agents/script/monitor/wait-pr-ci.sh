#!/usr/bin/env bash
# .agents/script/monitor/wait-pr-ci.sh - poll the check rollup of one or more PRs
# until they settle; the Monitor companion of the wait-pr-ci skill
# (.agents/skills/wait-pr-ci/SKILL.md).
#
# The loop lives here so the Monitor command stays one line (Claude Code's
# bash parser warns on parameter expansions inlined in a Monitor command).
# It prints one snapshot block per state change and exits when every PR is
# settled; the Monitor streams each block as a notification.
#
# worktool's branch protection requires exactly one check, the `ci-passed`
# aggregator (.github/workflows/ci.yml), so that is the default filter.
#
# Stale-rollup guards (kept from the version this script was ported from):
#   - watch-start completedAt guard: when every matching check completed
#     inside (watch_start - stale_window, watch_start), the rollup is taken
#     as carry-over from the previous head right after a force-push and is
#     demoted to "pending"; checks that completed earlier are trusted.
#   - headRefOid guard: when a PR's head moves between polls, one
#     `[head-moved] PR<n> <old7>..<new7>` line is printed and that PR is
#     "pending" for the poll.
#
# CLI contract (worktool): the whole command line is parsed before --help
# is served; `wait-pr-ci.sh: <problem> (see --help)` on stderr + exit 2 for
# any argument error; usage on stderr.
#
# Exit: 0 ALL_DONE (every PR all-pass + MERGEABLE), 1 FAIL (a check failed
# or a PR conflicts / its query fails), 2 argument error, 124 --max-iterations exhausted.
#
# Strict script: expected non-zero results are handled explicitly.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/lib/log.sh"

readonly DEFAULT_FILTER='.name=="ci-passed"'

# Settings (filled by _parse_args).
REPO=''
PRS=()
CHECK_FILTER="${DEFAULT_FILTER}"
MIN_CHECKS=1
INTERVAL=45
STALE_WINDOW=120
MAX_ITER=0

_usage() {
    cat >&2 <<'EOF'
Usage: wait-pr-ci.sh --repo <OWNER>/<REPO> --prs <N1,N2,...> [options]

Poll the check rollup of the given PRs until every one is all-pass and
MERGEABLE (ALL_DONE, exit 0) or one fails / conflicts (FAIL <pr>, exit 1).
Prints one snapshot block per state change:
  PR<n>: checks=<no-checks|pending|all-pass|FAIL> mergeable=<m>
  ---

Options:
  --repo <OWNER>/<REPO>     GitHub repo (required)
  --prs <CSV>               comma-separated PR numbers (required)
  --check-filter <jq-expr>  jq condition selecting the checks that count
                            (default: .name=="ci-passed")
  --min-checks <N>          matching checks required before all-pass
                            (default 1)
  --interval <seconds>      poll interval (default 45; 0 = no sleep)
  --stale-window <seconds>  force-push race window for the completedAt
                            guard (default 120; 0 = always demote)
  --max-iterations <N>      stop after N polls with exit 124 (default 0 =
                            unlimited; for tests)
  -h, --help                show this help and exit

Exit: 0 ALL_DONE, 1 FAIL / query error, 2 argument error, 124 max-iterations reached.
EOF
}

_usage_error() {
    printf 'wait-pr-ci.sh: %s (see --help)\n' "$1" >&2
    exit 2
}

# _need_int <option> <value> <min> - refuse a value that is not an integer
# >= min.
_need_int() {
    [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= $3 )) && return 0
    if [[ "$3" -ge 1 ]]; then
        _usage_error "$1 must be a positive integer (got: '$2')"
    fi
    _usage_error "$1 must be a non-negative integer (got: '$2')"
}

# _parse_args "$@" - the whole command line, before anything is served.
# Prints nothing; returns 0, or 3 when help was asked for (and the line is
# otherwise valid).
_parse_args() {
    local _help=0 _prs=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) _help=1; shift; continue ;;
            --repo|--prs|--check-filter|--min-checks|--interval|--stale-window|--max-iterations)
                [[ $# -ge 2 ]] || _usage_error "$1 needs a value" ;;
            *) _usage_error "unknown option '$1'" ;;
        esac
        case "$1" in
            --repo) REPO="$2" ;;
            --prs) _prs="$2" ;;
            --check-filter) CHECK_FILTER="$2" ;;
            --min-checks) MIN_CHECKS="$2" ;;
            --interval) INTERVAL="$2" ;;
            --stale-window) STALE_WINDOW="$2" ;;
            --max-iterations) MAX_ITER="$2" ;;
        esac
        shift 2
    done
    [[ "${_help}" -eq 1 ]] && return 3
    _validate "${_prs}"
}

# _validate <prs-csv> - required options and value checks.
_validate() {
    [[ -n "${REPO}" ]] || _usage_error "--repo is required"
    [[ -n "$1" ]] || _usage_error "--prs is required"
    [[ "$1" =~ ^[0-9]+(,[0-9]+)*$ ]] \
        || _usage_error "--prs must be comma-separated PR numbers (got: '$1')"
    IFS=',' read -ra PRS <<<"$1"
    _need_int --min-checks "${MIN_CHECKS}" 1
    _need_int --interval "${INTERVAL}" 0
    _need_int --stale-window "${STALE_WINDOW}" 0
    _need_int --max-iterations "${MAX_ITER}" 0
}

# _checks_state <pr-json> <watch-start> - the rollup state of the matching
# checks: no-checks | pending | all-pass | FAIL. Only SUCCESS passes: a
# completed check that was skipped, cancelled, timed out or anything else
# is FAIL, the same rule ci-passed applies to its gates (doc/structure.md,
# "CI").
_checks_state() {
    local _state
    _state="$(jq -r --argjson min "${MIN_CHECKS}" --argjson ws "$2" \
        --argjson sw "${STALE_WINDOW}" \
        "[.statusCheckRollup[]? | select(${CHECK_FILTER})] as \$c
        | if (\$c | length) == 0 then \"no-checks\"
          elif (\$c | length) < \$min then \"pending\"
          elif (\$c | any(.status != null and .status != \"COMPLETED\")) then \"pending\"
          elif (\$c | all(.conclusion == \"SUCCESS\")) then
            (if (\$c | all(.completedAt != null))
                and (\$c | all((.completedAt | fromdateiso8601) < \$ws))
                and (\$c | all((.completedAt | fromdateiso8601) > (\$ws - \$sw)))
             then \"pending\" else \"all-pass\" end)
          elif (\$c | any(.conclusion != null and .conclusion != \"SUCCESS\")) then \"FAIL\"
          else \"pending\" end" <<<"$1" 2>/dev/null)"
    printf '%s' "${_state:-pending}"
}

# The PR heads seen on the previous poll (headRefOid guard), and the result
# of the last _poll_pr call (set in this shell, never in a subshell, so the
# head map survives between polls).
declare -A HEAD_BY_PR=()
POLL_LINE=''
POLL_VERDICT=''

# _poll_pr <pr> <watch-start> - poll one PR: POLL_LINE = its snapshot line,
# POLL_VERDICT = ready | wait | fail-check | fail-conflict. A moved head
# prints one [head-moved] line and holds the PR at pending for this poll.
_poll_pr() {
    local _pr="$1" _json _oid _prev _state _m
    _json="$(gh pr view "${_pr}" --repo "${REPO}" \
        --json mergeable,statusCheckRollup,headRefOid)" || {
        log_error "wait-pr-ci.sh: failed to query ${REPO} PR${_pr}; resolve the gh error above and retry"
        return 1
    }
    _oid="$(jq -r '.headRefOid // ""' <<<"${_json}" 2>/dev/null)"
    _prev="${HEAD_BY_PR[${_pr}]:-}"
    HEAD_BY_PR[${_pr}]="${_oid}"
    _state="$(_checks_state "${_json}" "$2")"
    if [[ -n "${_prev}" && -n "${_oid}" && "${_oid}" != "${_prev}" ]]; then
        printf '[head-moved] PR%s %s..%s\n' "${_pr}" "${_prev:0:7}" "${_oid:0:7}"
        [[ "${_state}" == all-pass ]] && _state=pending
    fi
    _m="$(jq -r '.mergeable // "?"' <<<"${_json}" 2>/dev/null)"
    POLL_LINE="PR${_pr}: checks=${_state} mergeable=${_m:-?}"
    case "${_state}:${_m}" in
        FAIL:*) POLL_VERDICT=fail-check ;;
        all-pass:MERGEABLE) POLL_VERDICT=ready ;;
        all-pass:CONFLICTING) POLL_VERDICT=fail-conflict ;;
        *) POLL_VERDICT='wait' ;;
    esac
}

# _poll_all <watch-start> <prev-snapshot-var> - one poll over every PR.
# Prints the snapshot when it changed; returns 0 all ready, 1 a failure
# (FAIL line printed), 2 still waiting.
_poll_all() {
    local -n _prev_ref="$2"
    local _pr _out='' _rc=0 _fail=''
    for _pr in "${PRS[@]}"; do
        _poll_pr "${_pr}" "$1" || return 1
        _out+="${POLL_LINE}"$'\n'
        case "${POLL_VERDICT}" in
            ready) ;;
            fail-check) _fail="FAIL ${_pr}"; _rc=1 ;;
            fail-conflict)
                _fail="FAIL ${_pr} (mergeable=CONFLICTING): rebase the branch onto origin/main and push"
                _rc=1 ;;
            *) [[ "${_rc}" -eq 0 ]] && _rc=2 ;;
        esac
    done
    [[ "${_out}" != "${_prev_ref}" ]] && printf '%s---\n' "${_out}"
    _prev_ref="${_out}"
    [[ -n "${_fail}" ]] && printf '%s\n' "${_fail}"
    return "${_rc}"
}

main() {
    _parse_args "$@"
    if [[ $? -eq 3 ]]; then
        _usage
        return 0
    fi
    local _start _prev='' _iter=0 _rc
    _start="$(date -u +%s)"
    while :; do
        _iter=$((_iter + 1))
        _poll_all "${_start}" _prev
        _rc=$?
        [[ "${_rc}" -eq 1 ]] && return 1
        if [[ "${_rc}" -eq 0 ]]; then
            echo "ALL_DONE"
            return 0
        fi
        if (( MAX_ITER > 0 && _iter >= MAX_ITER )); then
            printf '[wait-pr-ci] max-iterations (%s) reached\n' "${MAX_ITER}" >&2
            return 124
        fi
        (( INTERVAL > 0 )) && sleep "${INTERVAL}"
    done
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    main "$@"
fi
