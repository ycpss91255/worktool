#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/ci_prior_run_spec.bats - lib/ci_prior_run.sh: a meta CI run
# (PR body / title / label edit, issue #688) may skip the code tiers only
# when the latest code run of the same head sha and PR passed every leg.
#
# Contract under test:
#   - ci_prior_run_select picks the newest code run (by run number) of the
#     PR, ignoring meta runs, the current run and other PRs' runs; it fails
#     when there is none or when that newest code run is not completed (an
#     older green run never stands in for a newer one);
#   - ci_prior_run_evaluate passes only when every expected leg (both
#     runners x build-image, the five gates, the unit shards,
#     test-system-real, plus the unit verdict, plus
#     verify-all when required) is present with conclusion success; a
#     missing, skipped, cancelled, failed or duplicated-non-success leg,
#     empty input or a bad verify flag fails, naming the leg;
#   - the library is pure: records come in on stdin, nothing calls the
#     GitHub API, no `set`, nothing on stdout at source time.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    # shellcheck source=../../lib/ci_prior_run.sh
    source "${LIB_DIR}/ci_prior_run.sh"
    # A skipped matrix job keeps its unexpanded name.
    SKIPPED_VERIFY="verify-all (\${{ matrix.runner }})"
}

# One run record: id, run_number, status, display_title, PR numbers.
_run() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$@"
}

# One job record per expected leg, all `completed success`, minus the names
# given as arguments.
_green_jobs() {
    local _verify="$1" _name _skip
    shift
    while IFS= read -r _name; do
        for _skip in "$@"; do
            [[ "${_name}" == "${_skip}" ]] && continue 2
        done
        printf '%s\tcompleted\tsuccess\n' "${_name}"
    done < <(ci_prior_run_expected_jobs "${_verify}")
}

# --- required spec / library guard ------------------------------------------

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "ci_prior_run.sh can be sourced without output and without changing shell options" {
    run bash -c 'before="$-"; source "$1"; [ "$-" = "${before}" ]' _ "${LIB_DIR}/ci_prior_run.sh"
    assert_success
    assert_output ''
}

# --- selecting the prior code run -------------------------------------------

@test "select picks the newest completed code run of this PR" {
    run ci_prior_run_select 900 7 < <(
        _run 900 50 in_progress 'CI meta run' 7
        _run 801 41 completed 'CI meta run' 7
        _run 800 40 completed 'CI code run' 7
        _run 700 30 completed 'CI code run' 7
        _run 990 60 completed 'CI code run' 8
    )
    assert_success
    assert_output 800
}

@test "select never lets an older green run stand in for a newer unfinished code run" {
    run ci_prior_run_select 900 7 < <(
        _run 820 42 in_progress 'CI code run' 7
        _run 800 40 completed 'CI code run' 7
    )
    assert_failure
    assert_output --partial '820'
    assert_output --partial 'in_progress'
}

@test "select fails when the PR has no code run for the head sha" {
    run ci_prior_run_select 900 7 < <(
        _run 900 50 in_progress 'CI code run' 7
        _run 801 41 completed 'CI meta run' 7
        _run 990 60 completed 'CI code run' 8
        _run 991 61 completed 'CI code run' ''
    )
    assert_failure
    assert_output --partial 'no code run'
}

@test "select matches the PR number as a whole word among several PRs" {
    run ci_prior_run_select 900 7 < <(_run 800 40 completed 'CI code run' '17 70')
    assert_failure
    run ci_prior_run_select 900 7 < <(_run 800 40 completed 'CI code run' '17 7')
    assert_success
    assert_output 800
}

@test "select rejects malformed arguments and records (fail closed)" {
    run ci_prior_run_select '' 7 < /dev/null
    assert_failure
    run ci_prior_run_select 900 x7 < /dev/null
    assert_failure
    run ci_prior_run_select 900 7 < <(_run abc 40 completed 'CI code run' 7)
    assert_failure
    run ci_prior_run_select 900 7 < <(_run 800 '' completed 'CI code run' 7)
    assert_failure
}

# --- evaluating its legs -----------------------------------------------------

@test "expected legs are both runners of build-image, five gates, four unit shards and test-system-real, plus the unit verdict" {
    run ci_prior_run_expected_jobs false
    assert_success
    assert_equal "${#lines[@]}" 23
    assert_line 'test-unit 1/4 (ubuntu-latest)'
    assert_line 'test-unit 4/4 (ubuntu-24.04-arm)'
    assert_line 'test-unit-verdict'
    refute_line 'test-unit (ubuntu-latest)'
    assert_line 'Build test image (ubuntu-latest)'
    assert_line 'Build test image (ubuntu-24.04-arm)'
    assert_line 'lint (ubuntu-24.04-arm)'
    assert_line 'test-acceptance (ubuntu-latest)'
    assert_line 'test-system-real (ubuntu-24.04-arm)'
    refute_line --partial 'verify-all'
    run ci_prior_run_expected_jobs true
    assert_success
    assert_equal "${#lines[@]}" 25
    assert_line 'verify-all (ubuntu-latest)'
    assert_line 'verify-all (ubuntu-24.04-arm)'
}

@test "evaluate passes when every expected leg succeeded, ignoring policy and aggregator jobs" {
    run ci_prior_run_evaluate false < <(
        _green_jobs false
        printf 'commit-attribution\tcompleted\tfailure\n'
        printf 'ci-passed\tcompleted\tfailure\n'
        printf '%s\tcompleted\tskipped\n' "${SKIPPED_VERIFY}"
    )
    assert_success
}

@test "evaluate fails and names a missing leg" {
    run ci_prior_run_evaluate false < <(_green_jobs false 'test-unit 2/4 (ubuntu-24.04-arm)')
    assert_failure
    assert_output --partial 'test-unit 2/4 (ubuntu-24.04-arm)'
    assert_output --partial 'missing'
}

@test "evaluate fails on a failed, skipped, cancelled or unfinished leg" {
    local _conclusion
    for _conclusion in failure skipped cancelled neutral ''; do
        run ci_prior_run_evaluate false < <(
            _green_jobs false 'lint (ubuntu-latest)'
            printf 'lint (ubuntu-latest)\tcompleted\t%s\n' "${_conclusion}"
        )
        assert_failure
        assert_output --partial 'lint (ubuntu-latest)'
    done
    run ci_prior_run_evaluate false < <(
        _green_jobs false 'lint (ubuntu-latest)'
        printf 'lint (ubuntu-latest)\tin_progress\t\n'
    )
    assert_failure
}

@test "evaluate fails when a leg appears twice and one copy is not success" {
    run ci_prior_run_evaluate false < <(
        _green_jobs false
        printf 'test-system (ubuntu-latest)\tcompleted\tfailure\n'
    )
    assert_failure
    assert_output --partial 'test-system (ubuntu-latest)'
}

@test "evaluate requires both verify-all legs only when verify is required" {
    run ci_prior_run_evaluate true < <(_green_jobs true)
    assert_success
    run ci_prior_run_evaluate true < <(
        _green_jobs false
        printf '%s\tcompleted\tskipped\n' "${SKIPPED_VERIFY}"
    )
    assert_failure
    assert_output --partial 'verify-all (ubuntu-latest)'
    run ci_prior_run_evaluate true < <(_green_jobs true 'verify-all (ubuntu-24.04-arm)')
    assert_failure
    assert_output --partial 'verify-all (ubuntu-24.04-arm)'
}

@test "evaluate fails closed on empty input and on a bad verify flag" {
    run ci_prior_run_evaluate false < /dev/null
    assert_failure
    run ci_prior_run_evaluate yes < <(_green_jobs true)
    assert_failure
    run ci_prior_run_evaluate '' < <(_green_jobs false)
    assert_failure
}
