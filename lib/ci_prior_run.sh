#!/usr/bin/env bash
# lib/ci_prior_run.sh - may a meta CI run skip the code tiers? (issue #688)
#
# A pull_request event that only edits the PR body, title or labels takes
# the meta path of .github/workflows/ci.yml: the code tiers are skipped and
# the run's ci-passed instead requires proof that the LATEST code-path run
# of the same head sha and PR finished with every test leg green. Nothing
# else counts: not an older green run while a newer one is unfinished, not
# that run's overall conclusion, not its ci-passed (a meta run would then
# vouch for another meta run). Every gap fails closed.
#
# The predicates are pure: records come in on stdin and nothing here calls
# the GitHub API; fetching the data is the workflow's job.
#
# Public API:
#   CI_PRIOR_RUN_CODE_TITLE / CI_PRIOR_RUN_META_TITLE
#       the legacy run names (`run-name:` of ci.yml) of the two paths.
#   ci_prior_run_select <current_run_id> <pr_number>   (run records on stdin)
#       stdin: one `<id>\t<run_number>\t<status>\t<display_title>\t<PR
#       numbers, space separated>` line per ci.yml run of the head sha.
#       -> prints the id of the newest (highest run number) code run of
#          that PR other than the current run and returns 0 when it is
#          completed; returns 3 (pending, an info line on stderr) when it is not
#          completed yet (#872), 1 when there is none or on any malformed
#          input. Runs of any
#          other name (meta runs, runs from before #688) never count.
#   ci_prior_run_await <max_polls> <poll_seconds> <current_run_id> <pr_number> -- <fetch...>
#       runs <fetch...> (it prints the run records ci_prior_run_select
#       reads) and selects; while the latest code run is pending (3) it
#       sleeps <poll_seconds> and fetches again, at most <max_polls> times
#       (#872: a body edit while the code run is still going must judge
#       that run, not fail before it ends). -> the selected id and 0; 1
#       when there is no code run, a fetch fails, the arguments are bad or
#       it is still pending after the last wait. The library itself never
#       calls the GitHub API: the caller passes the fetch.
#   ci_prior_run_expected_jobs <verify_required: true|false>
#       -> prints the check name of every leg that must be green, one per
#          line: both runners of build-image, the three gate legs, the unit
#          shards and test-system-real, plus verify-all when required, and
#          the single test-unit-verdict.
#   ci_prior_run_evaluate <verify_required: true|false>  (job records on stdin)
#       stdin: one `<name>\t<status>\t<conclusion>` line per job of the run.
#       -> 0 when every expected leg is present and every record of it is
#          `completed` / `success`; 1 otherwise, each offending leg named
#          on stderr. Other jobs (policy jobs, ci-passed) are ignored: the
#          meta run re-runs the policy jobs itself.
#
# This is a library: source it. It sets no shell options and prints nothing
# at source time.

# shellcheck source-path=SCRIPTDIR
_CI_PRIOR_RUN_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./log.sh
source "${_CI_PRIOR_RUN_LIB_DIR}/log.sh"

# The legacy run-name of each path of ci.yml.
CI_PRIOR_RUN_CODE_TITLE='CI code run'
CI_PRIOR_RUN_META_TITLE='CI meta run'

_CI_PRIOR_RUN_RUNNERS=(ubuntu-latest ubuntu-24.04-arm)
_CI_PRIOR_RUN_GATES=(lint-system-acceptance test-matrix test-integration)
# The unit tier runs as weighted shards plus one union verdict (issue #831);
# ci_yml_spec keeps this count equal to ci.yml's shard dimension.
_CI_PRIOR_RUN_UNIT_SHARDS=4

# Split the tab-separated line $1 into the array _ci_prior_run_fields,
# keeping empty fields (a plain `read` with IFS=tab would merge them).
_ci_prior_run_split() {
    _ci_prior_run_fields=()
    mapfile -t -d $'\t' _ci_prior_run_fields < <(printf '%s' "$1")
}

_ci_prior_run_is_number() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

_ci_prior_run_malformed() {
    log_error "ci_prior_run_select: malformed run record '$1' (fail closed)."
}

ci_prior_run_select() {
    local _current="${1:-}" _pr="${2:-}" _line _best='' _best_number=0 _best_status=''
    local _id _number _status _title _prs
    if (($# != 2)) || ! _ci_prior_run_is_number "${_current}" || ! _ci_prior_run_is_number "${_pr}"; then
        log_error 'ci_prior_run_select: expected <current_run_id> <pr_number> (fail closed).'
        return 1
    fi
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        [[ -n "${_line}" ]] || continue
        _ci_prior_run_split "${_line}"
        if ((${#_ci_prior_run_fields[@]} < 4 || ${#_ci_prior_run_fields[@]} > 5)); then
            _ci_prior_run_malformed "${_line}"
            return 1
        fi
        _id="${_ci_prior_run_fields[0]}"
        _number="${_ci_prior_run_fields[1]}"
        _status="${_ci_prior_run_fields[2]}"
        _title="${_ci_prior_run_fields[3]}"
        _prs="${_ci_prior_run_fields[4]:-}"
        if ! _ci_prior_run_is_number "${_id}" || ! _ci_prior_run_is_number "${_number}"; then
            _ci_prior_run_malformed "${_line}"
            return 1
        fi
        [[ "${_id}" != "${_current}" ]] || continue
        # Only the fixed code prefix can identify a new-format run; the
        # untrusted PR title after the separator never determines the path.
        [[ "${_title}" == "${CI_PRIOR_RUN_CODE_TITLE}" || "${_title}" == "${CI_PRIOR_RUN_CODE_TITLE} · PR #${_pr} · "* ]] || continue
        [[ " ${_prs} " == *" ${_pr} "* ]] || continue
        if ((_number > _best_number)); then
            _best="${_id}"
            _best_number="${_number}"
            _best_status="${_status}"
        fi
    done
    if [[ -z "${_best}" ]]; then
        log_error "ci_prior_run_select: no code run of PR #${_pr} for this head sha (a '${CI_PRIOR_RUN_META_TITLE}' never counts); push or re-run CI (fail closed)."
        return 1
    fi
    if [[ "${_best_status}" != completed ]]; then
        log_info "ci_prior_run_select: the latest code run ${_best} is ${_best_status}, not completed yet (pending)."
        return 3
    fi
    printf '%s\n' "${_best}"
}

ci_prior_run_expected_jobs() {
    local _verify="${1:-}" _runner _gate
    case "${_verify}" in
        true | false) ;;
        *)
            log_error "ci_prior_run_expected_jobs: verify_required must be true or false, got '${_verify}'."
            return 1
            ;;
    esac
    for _runner in "${_CI_PRIOR_RUN_RUNNERS[@]}"; do
        printf 'Build test image (%s)\n' "${_runner}"
        for _gate in "${_CI_PRIOR_RUN_GATES[@]}"; do
            printf '%s (%s)\n' "${_gate}" "${_runner}"
        done
        for ((_gate = 1; _gate <= _CI_PRIOR_RUN_UNIT_SHARDS; _gate++)); do
            printf 'test-unit %d/%d (%s)\n' "${_gate}" "${_CI_PRIOR_RUN_UNIT_SHARDS}" "${_runner}"
        done
        printf 'test-system-real (%s)\n' "${_runner}"
        if [[ "${_verify}" == true ]]; then
            printf 'verify-all (%s)\n' "${_runner}"
        fi
    done
    printf 'test-unit-verdict\n'
}

ci_prior_run_evaluate() {
    local _expected _line _name _bad=0 _n=0
    local -A _want=() _seen=() _green=()
    _expected="$(ci_prior_run_expected_jobs "${1:-}")" || return 1
    while IFS= read -r _name; do
        _want["${_name}"]=1
    done <<< "${_expected}"
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        [[ -n "${_line}" ]] || continue
        _ci_prior_run_split "${_line}"
        _name="${_ci_prior_run_fields[0]}"
        [[ -n "${_want["${_name}"]:-}" ]] || continue
        if [[ "${_ci_prior_run_fields[1]:-}" == completed && "${_ci_prior_run_fields[2]:-}" == success ]]; then
            [[ -n "${_seen["${_name}"]:-}" ]] || _green["${_name}"]=1
        else
            _green["${_name}"]=0
            log_error "prior code run: ${_name} is ${_ci_prior_run_fields[1]:-?}/${_ci_prior_run_fields[2]:-none}, not completed/success."
        fi
        _seen["${_name}"]=1
    done
    while IFS= read -r _name; do
        _n=$((_n + 1))
        if [[ -z "${_seen["${_name}"]:-}" ]]; then
            log_error "prior code run: ${_name} is missing."
            _bad=$((_bad + 1))
        elif [[ "${_green["${_name}"]}" != 1 ]]; then
            _bad=$((_bad + 1))
        fi
    done <<< "${_expected}"
    if ((_bad > 0)); then
        log_error "prior code run: ${_bad} of ${_n} required legs are not green (fail closed)."
        return 1
    fi
    log_info "prior code run: all ${_n} required legs are green."
}

ci_prior_run_await() {
    local _polls="${1:-}" _secs="${2:-}" _current="${3:-}" _pr="${4:-}" _records _id _rc _i
    if (($# < 6)) || [[ "${5}" != -- ]] || [[ ! "${_polls}" =~ ^[0-9]+$ ]] || ! _ci_prior_run_is_number "${_secs}"; then
        log_error 'ci_prior_run_await: expected <max_polls> <poll_seconds> <current_run_id> <pr_number> -- <fetch...> (fail closed).'
        return 1
    fi
    shift 5
    for ((_i = 0; ; _i++)); do
        if ! _records="$("$@")"; then
            log_error 'ci_prior_run_await: fetching the runs of the head sha failed (fail closed).'
            return 1
        fi
        _rc=0
        _id="$(ci_prior_run_select "${_current}" "${_pr}" <<<"${_records}")" || _rc=$?
        if ((_rc == 0)); then
            printf '%s\n' "${_id}"
            return 0
        fi
        ((_rc == 3)) || return 1
        if ((_i >= _polls)); then
            log_error "ci_prior_run_await: the latest code run is still not completed after ${_polls} waits of ${_secs}s (fail closed)."
            return 1
        fi
        log_info "ci_prior_run_await: waiting ${_secs}s for the latest code run to finish (${_i}/${_polls})."
        sleep "${_secs}"
    done
}
