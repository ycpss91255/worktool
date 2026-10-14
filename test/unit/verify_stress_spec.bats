#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"

@test "stress: CPU repro cases skip unless explicitly enabled" {
    local spec probe="${BATS_TEST_TMPDIR}/probe.bats" value
    for spec in verify_run_signal verify_realbox; do
        sed -n '/^@test .*HUP under CPU load/,/^}/p' \
            "${BATS_TEST_DIRNAME}/${spec}_spec.bats" |
            sed '/^    load /d; s/^    interrupt_load_start$/    return 1/' >"${probe}"
        for value in unset 0; do
            if [[ "${value}" == unset ]]; then
                run env -u WORKTOOL_STRESS bats --formatter tap "${probe}"
            else
                run env WORKTOOL_STRESS="${value}" bats --formatter tap "${probe}"
            fi
            assert_success
            assert_output --partial '# skip'
        done
        run env WORKTOOL_STRESS=1 bats --formatter tap "${probe}"
        assert_failure
        refute_output --partial '# skip'
    done
}
