#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/verify_ci_gate_spec.bats - lib/verify_ci_gate.sh (issue #833)
#
# WHAT THIS PROVES
#   In CI, acceptance items 2.1 and 2.3 judge the gate jobs of their own run
#   instead of running the tiers again, and that judgement fails closed: a
#   job that is missing, listed twice, still running, skipped, cancelled,
#   failed, or of another head sha or run is a failure that names the job.
#   A partial CI request (one of run / sha / repo missing) is an error, not
#   a silent local run. The runner set the lib judges is the one ci.yml's
#   gate matrix runs on.
#
# HOW
#   The lib is sourced in the bats shell; the job list is a TSV fixture in
#   the shape verify_ci_gate_fetch_jobs writes. No gh, no network.

load "${BATS_TEST_DIRNAME}/../helper/common"

SHA=0123456789abcdef0123456789abcdef01234567
RUN=4242

setup() {
    # shellcheck source=../../lib/verify_ci_gate.sh
    source "${REPO_ROOT}/lib/verify_ci_gate.sh"
    JOBS="${BATS_TEST_TMPDIR}/jobs.tsv"
    unset WORKTOOL_VERIFY_GATE_RUN WORKTOOL_VERIFY_GATE_SHA WORKTOOL_VERIFY_GATE_REPO
}

# _job <name> [sha] [run] [status] [conclusion] [id]
_job() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "${2:-${SHA}}" "${3:-${RUN}}" \
        "${4:-completed}" "${5:-success}" "${6:-7}"
}

@test "mode: nothing set is a local run (1); all three set and well-formed is CI (0)" {
    run verify_ci_gate_mode
    assert_failure 1
    assert_output ""
    WORKTOOL_VERIFY_GATE_RUN="${RUN}" WORKTOOL_VERIFY_GATE_SHA="${SHA}" \
        WORKTOOL_VERIFY_GATE_REPO=owner/repo run verify_ci_gate_mode
    assert_success
}

@test "mode: a partial request is an error (2) naming what is unset, never a local run" {
    WORKTOOL_VERIFY_GATE_RUN="${RUN}" run verify_ci_gate_mode
    assert_failure 2
    assert_output --partial 'must be set together'
    assert_output --partial 'sha=<unset>'
}

@test "mode: a malformed run id, sha or repo is an error (2)" {
    WORKTOOL_VERIFY_GATE_RUN=abc WORKTOOL_VERIFY_GATE_SHA="${SHA}" \
        WORKTOOL_VERIFY_GATE_REPO=owner/repo run verify_ci_gate_mode
    assert_failure 2
    WORKTOOL_VERIFY_GATE_RUN="${RUN}" WORKTOOL_VERIFY_GATE_SHA=HEAD \
        WORKTOOL_VERIFY_GATE_REPO=owner/repo run verify_ci_gate_mode
    assert_failure 2
    WORKTOOL_VERIFY_GATE_RUN="${RUN}" WORKTOOL_VERIFY_GATE_SHA="${SHA}" \
        WORKTOOL_VERIFY_GATE_REPO='owner/repo;x' run verify_ci_gate_mode
    assert_failure 2
}

@test "job names: lint is lint, every other step is test-<step>, each with its runner" {
    run verify_ci_gate_job_name lint ubuntu-latest
    assert_output 'lint (ubuntu-latest)'
    run verify_ci_gate_job_name unit ubuntu-24.04-arm
    assert_output 'test-unit (ubuntu-24.04-arm)'
    run verify_ci_gate_job_name system-real ubuntu-latest
    assert_output 'test-system-real (ubuntu-latest)'
}

@test "evaluate: every job completed, success, same sha and run passes and lists what it reused" {
    { _job 'lint (ubuntu-latest)' "" "" "" "" 11; _job 'test-unit (ubuntu-latest)' "" "" "" "" 12; } >"${JOBS}"
    run verify_ci_gate_evaluate "${JOBS}" "${SHA}" "${RUN}" 'lint (ubuntu-latest)' 'test-unit (ubuntu-latest)'
    assert_success
    assert_line --index 0 "reused: lint (ubuntu-latest) success run=${RUN} job=11"
    assert_line --index 1 "reused: test-unit (ubuntu-latest) success run=${RUN} job=12"
    assert_equal "${#lines[@]}" 2
}

@test "evaluate: a missing job fails and names it" {
    _job 'lint (ubuntu-latest)' >"${JOBS}"
    run verify_ci_gate_evaluate "${JOBS}" "${SHA}" "${RUN}" 'lint (ubuntu-latest)' 'test-unit (ubuntu-latest)'
    assert_failure 1
    assert_output --partial 'job "test-unit (ubuntu-latest)" appears 0 times'
}

@test "evaluate: a job listed twice fails (an ambiguous attempt is not evidence)" {
    { _job 'lint (ubuntu-latest)'; _job 'lint (ubuntu-latest)'; } >"${JOBS}"
    run verify_ci_gate_evaluate "${JOBS}" "${SHA}" "${RUN}" 'lint (ubuntu-latest)'
    assert_failure 1
    assert_output --partial 'appears 2 times'
}

@test "evaluate: skipped, cancelled, failure and no conclusion all fail and name the job" {
    local _c
    for _c in skipped cancelled failure none; do
        _job 'lint (ubuntu-latest)' "" "" completed "${_c}" >"${JOBS}"
        run verify_ci_gate_evaluate "${JOBS}" "${SHA}" "${RUN}" 'lint (ubuntu-latest)'
        assert_failure 1
        assert_output --partial "job \"lint (ubuntu-latest)\" concluded ${_c}, not success"
        refute_output --partial 'reused:'
    done
}

@test "evaluate: a job still running fails" {
    _job 'lint (ubuntu-latest)' "" "" in_progress none >"${JOBS}"
    run verify_ci_gate_evaluate "${JOBS}" "${SHA}" "${RUN}" 'lint (ubuntu-latest)'
    assert_failure 1
    assert_output --partial 'is in_progress, not completed'
}

@test "evaluate: a job of another head sha or another run fails" {
    _job 'lint (ubuntu-latest)' fedcba9876543210fedcba9876543210fedcba98 >"${JOBS}"
    run verify_ci_gate_evaluate "${JOBS}" "${SHA}" "${RUN}" 'lint (ubuntu-latest)'
    assert_failure 1
    assert_output --partial 'ran on fedcba9876543210fedcba9876543210fedcba98, not the head'
    _job 'lint (ubuntu-latest)' "" 999 >"${JOBS}"
    run verify_ci_gate_evaluate "${JOBS}" "${SHA}" "${RUN}" 'lint (ubuntu-latest)'
    assert_failure 1
    assert_output --partial 'belongs to run 999'
}

@test "evaluate: one bad job fails the whole judgement while the good ones are still listed" {
    { _job 'lint (ubuntu-latest)'; _job 'test-unit (ubuntu-latest)' "" "" completed failure; } >"${JOBS}"
    run verify_ci_gate_evaluate "${JOBS}" "${SHA}" "${RUN}" 'lint (ubuntu-latest)' 'test-unit (ubuntu-latest)'
    assert_failure 1
    assert_line --partial 'reused: lint (ubuntu-latest)'
    assert_output --partial 'test-unit (ubuntu-latest)" concluded failure'
}

@test "evaluate: an unreadable job list fails" {
    run verify_ci_gate_evaluate "${BATS_TEST_TMPDIR}/missing.tsv" "${SHA}" "${RUN}" 'lint (ubuntu-latest)'
    assert_failure 1
}

@test "the runners judged are exactly ci.yml's gate matrix runners" {
    run sed -nE '/^  gate:$/,/^  [a-z-]+:$/ s/^        runner: \[(.*)\]$/\1/p' "${REPO_ROOT}/.github/workflows/ci.yml"
    assert_success
    assert_output "$(verify_ci_gate_runners | paste -sd, - | sed 's/,/, /g')"
}

@test "lib/verify_ci_gate.sh sets no shell options (it is sourced)" {
    run grep -nE '^[[:space:]]*set -' "${REPO_ROOT}/lib/verify_ci_gate.sh"
    assert_failure 1
}
