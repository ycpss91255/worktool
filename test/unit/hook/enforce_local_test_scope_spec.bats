#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

_check() { run_hook enforce_local_test_scope "$(hook_json "$1")"; }

@test "heavy test tiers are reserved for CI even with a spec" {
    _check 'just test matrix test/matrix/example_spec.bats'
    assert_failure 2
    assert_output --partial 'ci-passed'
    assert_output --partial 'lint'
    assert_output --partial 'unit spec'
}

@test "bare tests and whole unit tiers are blocked through shell wrappers" {
    _check "bash -c 'just test unit --filter example'"
    assert_failure 2
    _check "eval 'just test'"
    assert_failure 2
}

@test "direct test script heavy flags cannot bypass the local scope guard" {
    _check "eval 'bash script/test/test.sh --system-real test/system-real/example_spec.bats'"
    assert_failure 2
    _check 'script/test/test.sh --unit'
    assert_failure 2
    _check 'script/test/test.sh'
    assert_failure 2
}

@test "light tests selected unit specs and help remain allowed" {
    _check 'just test lint'
    assert_success
    _check 'just test changed'
    assert_success
    _check "bash -c 'just test unit test/unit/log_spec.bats --filter example'"
    assert_success
    _check 'script/test/test.sh --unit test/unit/log_spec.bats'
    assert_success
    _check 'just test matrix --help'
    assert_success
    _check 'script/test/test.sh --help'
    assert_success
    _check "printf '%s' 'just test matrix'"
    assert_success
}
