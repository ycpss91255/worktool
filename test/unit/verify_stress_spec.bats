#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"

@test "stress: cleanup stops workers that inherit ignored TERM" {
    run bash -c '
        exec 3>&-
        trap "" TERM
        source "$1/test/helper/interrupt_load.bash"
        interrupt_load_start
        workers=("${INTERRUPT_LOAD_PIDS[@]}")
        (
            sleep 2
            for pid in "${workers[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    printf "worker survived cleanup\n"
                    kill -KILL "$pid"
                fi
            done
        ) &
        watchdog=$!
        interrupt_load_stop
        wait "$watchdog"
        interrupt_load_stop
    ' _ "${REPO_ROOT}"
    assert_success
    refute_output --partial 'worker survived cleanup'
}

# Fail at the first external tool after load starts, without changing the spec.
prepare_stress_failure() {
    local bin="${BATS_TEST_TMPDIR}/failure-bin"
    mkdir -p "${bin}"
    cat >"${bin}/sed" <<'STUB'
#!/usr/bin/env bash
printf 'forced stress fixture failure\n' >&2
exit 1
STUB
    chmod +x "${bin}/sed"
    export PATH="${bin}:${PATH}"
}

@test "stress: CPU repro cases skip unless explicitly enabled" {
    local spec value
    prepare_stress_failure
    for spec in verify_run_signal verify_realbox; do
        for value in unset 0; do
            if [[ "${value}" == unset ]]; then
                run env -u WORKTOOL_STRESS bats --formatter tap --filter 'HUP under CPU load' \
                    "${BATS_TEST_DIRNAME}/${spec}_spec.bats"
            else
                run env WORKTOOL_STRESS="${value}" bats --formatter tap --filter 'HUP under CPU load' \
                    "${BATS_TEST_DIRNAME}/${spec}_spec.bats"
            fi
            assert_success
            assert_line '1..1'
            assert_output --partial '# skip set WORKTOOL_STRESS=1 to run CPU repro'
            refute_output --partial 'forced stress fixture failure'
        done
        run env WORKTOOL_STRESS=1 bats --formatter tap --filter 'HUP under CPU load' \
            "${BATS_TEST_DIRNAME}/${spec}_spec.bats"
        assert_failure
        assert_line '1..1'
        assert_output --partial 'forced stress fixture failure'
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
