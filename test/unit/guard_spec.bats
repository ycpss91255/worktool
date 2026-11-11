#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    bats_require_minimum_version 1.5.0
    # shellcheck source=lib/guard.sh
    source "${LIB_DIR}/guard.sh"
}

@test "#576: zero matching lines returns zero without aborting an errexit caller" {
    printf 'other\n' >"${BATS_TEST_TMPDIR}/input"

    run bash -c '
        set -euo pipefail
        source "$1/guard.sh"
        guard_count_lines "$2" "^missing$"
        printf "returned=%s\n" "$?"
    ' _ "${LIB_DIR}" "${BATS_TEST_TMPDIR}/input"

    assert_success
    assert_output $'0\nreturned=0'
}

@test "guard_fail reports a failure on stderr and returns one" {
    run --separate-stderr guard_fail 'broken check'
    assert_failure 1
    assert_output ''
    assert_equal "${stderr:-}" '[FAIL] broken check'
}

@test "guard_require succeeds silently when all tools exist" {
    run --separate-stderr guard_require bash printf
    assert_success
    assert_output ''
    assert_equal "${stderr:-}" ''
}

@test "guard_require reports every unavailable tool and returns three" {
    run --separate-stderr guard_require bash worktool_missing_guard_a worktool_missing_guard_b
    assert_failure 3
    assert_output ''
    [[ "${stderr:-}" == *'worktool_missing_guard_a not found on PATH'* ]]
    [[ "${stderr:-}" == *'worktool_missing_guard_b not found on PATH'* ]]
}

@test "guard_timed preserves command status and output" {
    run guard_timed 5 bash -c 'printf result; exit 7'
    assert_failure 7
    assert_output 'result'
}

@test "guard_timed reports a timeout" {
    run guard_timed 0.01 sleep 1
    assert_failure 124
}
