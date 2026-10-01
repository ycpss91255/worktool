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
