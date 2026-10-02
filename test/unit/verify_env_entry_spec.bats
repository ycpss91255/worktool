#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"

@test "verify-env parses all options before help and rejects unknown options" {
    run just -f "${REPO_ROOT}/justfile" test verify-env --help --invalid
    assert_failure 2
    assert_output --partial "verify-env.sh: unknown option '--invalid' (see --help)"
    run just -f "${REPO_ROOT}/justfile" test verify-env --help
    assert_success
    assert_output --partial 'Usage: just test verify-env'
}
