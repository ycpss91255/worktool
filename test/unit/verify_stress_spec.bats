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

@test "stress: teardown stops every load worker and can run twice" {
    local spec cleanup="${BATS_TEST_TMPDIR}/cleanup.bash"
    for spec in verify_run_signal verify_realbox; do
        sed -n '/^teardown() {/,/^}/p; /^signal_child_stop() {/,/^}/p' \
            "${BATS_TEST_DIRNAME}/${spec}_spec.bats" >"${cleanup}"
        run bash -c '
            exec 3>&-
            source "$1/test/helper/interrupt_load.bash"
            source "$2"
            export SIGNAL_STATE="$3"
            trap interrupt_load_stop EXIT
            interrupt_load_start
            workers=("${INTERRUPT_LOAD_PIDS[@]}")
            teardown || exit 1
            teardown || exit 1
            for pid in "${workers[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    printf "load worker still alive: %s\n" "$pid"
                    exit 1
                fi
            done
        ' _ "${REPO_ROOT}" "${cleanup}" "${BATS_TEST_TMPDIR}"
        assert_success
    done
}
