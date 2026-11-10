#!/usr/bin/env bash
# lib/verify_ci_gate.sh - acceptance items 2.1 and 2.3 in CI read the gate
# jobs of their OWN run instead of running the tiers again (issue #833,
# decision recorded on #824 item 1).
#
# On a milestone-gate PR, verify-all runs after the gate jobs of the same
# workflow run. Those jobs already ran every tier of bare `just test` on
# both runners against the same head sha, so running them again inside
# verify-all only repeats them. Instead the verify-all step names its run
# (WORKTOOL_VERIFY_GATE_RUN / _SHA / _REPO) and these functions judge that
# run's jobs, fail closed: a job that is missing, listed twice, not
# completed, skipped, cancelled, anything but success, or of another sha or
# run fails the item. Locally nothing is set and 2.1 / 2.3 run the tiers
# themselves, unchanged.
#
# Sourced: provides functions only, sets no shell options. Diagnostics go
# to stderr; stdout carries only the reused-job lines the document shows.

# The runners every gate leg runs on (.github/workflows/ci.yml matrix
# `runner:`; test/unit/verify_ci_gate_spec.bats keeps the two equal).
verify_ci_gate_runners() {
    printf '%s\n' ubuntu-latest ubuntu-24.04-arm
}

# Seconds one GitHub API call (job list, one job log) may take.
VERIFY_CI_GATE_TIMEOUT="${VERIFY_CI_GATE_TIMEOUT:-300}"

# 0 when CI mode is requested and complete, 1 when it is not requested
# (local run). A partial request (one or two of the three set) is an error:
# it prints why and returns 2, so a typo can never fall back to a local run
# that the caller did not ask for, nor to a CI judgement of nothing.
verify_ci_gate_mode() {
    local _run="${WORKTOOL_VERIFY_GATE_RUN:-}" _sha="${WORKTOOL_VERIFY_GATE_SHA:-}"
    local _repo="${WORKTOOL_VERIFY_GATE_REPO:-}"
    if [[ -z "${_run}${_sha}${_repo}" ]]; then
        return 1
    fi
    if [[ -z "${_run}" || -z "${_sha}" || -z "${_repo}" ]]; then
        printf '[ERROR] verify_ci_gate: WORKTOOL_VERIFY_GATE_RUN, _SHA and _REPO must be set together (run=%s sha=%s repo=%s)\n' \
            "${_run:-<unset>}" "${_sha:-<unset>}" "${_repo:-<unset>}" >&2
        return 2
    fi
    if [[ ! "${_run}" =~ ^[1-9][0-9]*$ || ! "${_sha}" =~ ^[0-9a-f]{40}$ \
        || ! "${_repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        printf '[ERROR] verify_ci_gate: malformed CI gate request (run=%s sha=%s repo=%s)\n' \
            "${_run}" "${_sha}" "${_repo}" >&2
        return 2
    fi
    return 0
}

# The gate job name of one bare `just test` step on one runner: ci.yml
# names the gate `lint`, `test-<tier>` or `test-system-real`, and every leg
# carries its runner. $1 = step, $2 = runner.
verify_ci_gate_job_name() {
    case "$1" in
        lint) printf 'lint (%s)\n' "$2" ;;
        *)    printf 'test-%s (%s)\n' "$1" "$2" ;;
    esac
}

# Write the latest attempt of every job of run $2 in repo $1 to file $3, one
# TSV line per job: name, head_sha, run_id, status, conclusion, id. Returns
# non-zero when the query fails (the caller fails closed).
verify_ci_gate_fetch_jobs() {
    local _repo="$1" _run="$2" _out="$3"
    timeout -k 5 "${VERIFY_CI_GATE_TIMEOUT}" gh api --paginate \
        "repos/${_repo}/actions/runs/${_run}/jobs?filter=latest&per_page=100" \
        --jq '.jobs[] | [.name, .head_sha, (.run_id | tostring), .status, (.conclusion // "none"), (.id | tostring)] | @tsv' \
        >"${_out}"
}

# Judge the job list in TSV file $1 (verify_ci_gate_fetch_jobs) against
# sha $2 and run $3 for every job name after them. Prints one
# `reused: <name> success run=<run> job=<id>` line per good job on stdout
# and names every problem on stderr; returns 1 when any job is not good.
verify_ci_gate_evaluate() {
    local _file="$1" _sha="$2" _run="$3"
    shift 3
    local _name _rows _count _line _bad=0
    local _n _hsha _rid _status _concl _id
    [[ -r "${_file}" ]] || {
        printf '[ERROR] verify_ci_gate: job list %s is unreadable\n' "${_file}" >&2
        return 1
    }
    for _name in "$@"; do
        _rows="$(awk -F '\t' -v n="${_name}" '$1 == n' "${_file}")"
        _count=0
        [[ -z "${_rows}" ]] || _count="$(printf '%s\n' "${_rows}" | wc -l)"
        if [[ "${_count}" -ne 1 ]]; then
            printf '[ERROR] verify_ci_gate: job "%s" appears %s times in run %s (want exactly 1)\n' \
                "${_name}" "${_count}" "${_run}" >&2
            _bad=1
            continue
        fi
        _line="${_rows}"
        IFS=$'\t' read -r _n _hsha _rid _status _concl _id <<<"${_line}"
        if [[ "${_rid}" != "${_run}" ]]; then
            printf '[ERROR] verify_ci_gate: job "%s" belongs to run %s, not %s\n' "${_name}" "${_rid}" "${_run}" >&2
            _bad=1
        elif [[ "${_hsha}" != "${_sha}" ]]; then
            printf '[ERROR] verify_ci_gate: job "%s" ran on %s, not the head %s\n' "${_name}" "${_hsha}" "${_sha}" >&2
            _bad=1
        elif [[ "${_status}" != completed ]]; then
            printf '[ERROR] verify_ci_gate: job "%s" is %s, not completed\n' "${_name}" "${_status}" >&2
            _bad=1
        elif [[ "${_concl}" != success ]]; then
            printf '[ERROR] verify_ci_gate: job "%s" concluded %s, not success\n' "${_name}" "${_concl}" >&2
            _bad=1
        else
            printf 'reused: %s success run=%s job=%s\n' "${_name}" "${_run}" "${_id}"
        fi
    done
    return "${_bad}"
}

# The id of job $2 in TSV file $1 (already judged by verify_ci_gate_evaluate).
verify_ci_gate_job_id() {
    awk -F '\t' -v n="$2" '$1 == n { print $6; exit }' "$1"
}

# Write the log of job $2 in repo $1 to file $3 with the runner's timestamp
# prefix and colour codes removed, so each line reads as the tier printed
# it. Returns non-zero when the download fails or the log is empty.
verify_ci_gate_fetch_log() {
    local _repo="$1" _job="$2" _out="$3" _raw="$3.raw"
    timeout -k 5 "${VERIFY_CI_GATE_TIMEOUT}" gh api --allow-escape-sequences "repos/${_repo}/actions/jobs/${_job}/logs" >"${_raw}" || return 1
    sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' "${_raw}" >"${_out}" || return 1
    rm -f -- "${_raw}"
    [[ -s "${_out}" ]]
}
