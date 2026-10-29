#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"

@test "hook state guard passes clean specs and rejects leaked state in teardown_file" {
    local project="${BATS_TEST_TMPDIR}/project"
    mkdir -p "${project}/test/helper" "${project}/.agents/state"
    cp "${REPO_ROOT}/test/helper/common.bash" \
        "${REPO_ROOT}/test/helper/hook_state.bash" "${project}/test/helper/"
    cat > "${project}/fixture.bats" <<'FIXTURE'
#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/test/helper/common"
load "${BATS_TEST_DIRNAME}/test/helper/hook_state"

setup_file() { hook_state_guard_begin; }
teardown_file() { hook_state_guard_end; }

@test "fixture optionally leaves a state file" {
    if [[ "${LEAK_STATE}" == 1 ]]; then
        printf 'snapshot\n' > "${REPO_ROOT}/.agents/state/leaked-snapshot"
    fi
}
FIXTURE

    run env LEAK_STATE=0 bats --formatter tap "${project}/fixture.bats"
    assert_success
    assert_output --partial 'ok 1 fixture optionally leaves a state file'
    refute_output --partial 'teardown_file failed'

    run env LEAK_STATE=1 bats --formatter tap "${project}/fixture.bats"
    assert_failure
    assert_output --partial 'ok 1 fixture optionally leaves a state file'
    assert_output --partial 'not ok 2 teardown_file failed'
    assert_output --partial "${project}/.agents/state/leaked-snapshot"
}
