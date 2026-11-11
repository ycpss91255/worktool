#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# Unit spec for lib/nightly.sh (issue #836): when the nightly full serial
# run runs, and what it reports, around the open `nightly-failure` issue.

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

setup() {
    # shellcheck source=../../lib/nightly.sh
    source "${LIB_DIR}/nightly.sh"
}

@test "a scheduled run skips while a nightly-failure issue is open, and says which" {
    run --separate-stderr nightly_decide schedule 0 $'41\n17'
    assert_success
    assert_output 'skip 17'
    [[ "${stderr:-}" == *'#17'* ]] || fail "the skip does not name the open issue: ${stderr:-}"
}

@test "the nightly decision and report cover every branch" {
    local _case _args _want
    while IFS='|' read -r _case _want; do
        read -r -a _args <<<"${_case}"
        run --separate-stderr "${_args[@]}"
        assert_success
        assert_output "${_want}"
    done <<'CASES'
nightly_decide schedule 0|run
nightly_decide schedule 1 17|run
nightly_decide workflow_dispatch 0 17|run
nightly_decide workflow_dispatch 1|run
nightly_report failure 0|open
nightly_report cancelled 0|open
nightly_report failure 0 17|comment 17
nightly_report success 0 17|comment 17
nightly_report success 0|none
nightly_report failure 2|open
nightly_report success 2|none
CASES
    run --separate-stderr nightly_decide schedule 1
    [[ "${stderr:-}" == *'running anyway'* ]] || fail "a failed listing must say it runs anyway: ${stderr:-}"
}

@test "nightly_check_sha accepts an empty input or a full 40-hex sha and refuses the rest (#837)" {
    run nightly_check_sha ""
    assert_success
    run nightly_check_sha 0123456789abcdef0123456789abcdef01234567
    assert_success
    local _bad
    for _bad in main HEAD 0123456 "0123456789abcdef0123456789abcdef0123456X" "$(printf 'a%.0s' {1..41})"; do
        run nightly_check_sha "${_bad}"
        assert_failure 2
    done
}

# #851: a main push runs the full check on every merged sha, so a
# scheduled run only fills the gap - when main's HEAD has no green full run
# yet. Argument 4 is full-run.sh's exit status for HEAD (this run excluded):
# 0 green, 3 another run of HEAD still going, anything else (1, empty) none.
@test "a scheduled run skips when main's HEAD already has a green full run or one is running (#851)" {
    run --separate-stderr nightly_decide schedule 0 "" 0
    assert_success
    assert_output 'skip-green'
    [[ "${stderr:-}" == *'already has a green full run'* ]] || fail "no reason logged: ${stderr:-}"
    run --separate-stderr nightly_decide schedule 0 "" 3
    assert_success
    assert_output 'skip-running'
    run --separate-stderr nightly_decide schedule 0 "" 1
    assert_output 'run'
    run --separate-stderr nightly_decide schedule 0 ""
    assert_output 'run'
    # An open failure issue still wins (no duplicate run, no new comment).
    run --separate-stderr nightly_decide schedule 0 17 1
    assert_output 'skip 17'
}

@test "a main push always runs the full check (#851)" {
    run --separate-stderr nightly_decide push 0 17 0
    assert_success
    assert_output 'run'
}
