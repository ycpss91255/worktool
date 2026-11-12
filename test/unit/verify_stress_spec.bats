#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"

# Count the original process even if its group changes; only kill in its recorded group.
stress_worker_alive() {
    local pid="$1" start="$2" row state actual_start
    [[ -r "/proc/${pid}/stat" ]] || return 1
    IFS= read -r row <"/proc/${pid}/stat" || return 1
    local -a fields
    read -r -a fields <<<"${row##*) }"
    state="${fields[0]}"; actual_start="${fields[19]}"
    [[ "${state}" != Z && "${actual_start}" == "${start}" ]] || return 1
    return 0
}

stress_record_worker() {
    local pid="$1" row
    IFS= read -r row <"/proc/${pid}/stat" || return 1
    local -a fields
    read -r -a fields <<<"${row##*) }"
    printf '%s %s %s\n' "${pid}" "${fields[19]}" "${fields[2]}"
}

stress_check_workers() {
    local pid start group comm row survived=0
    local -a fields
    while read -r pid start group; do
        if stress_worker_alive "${pid}" "${start}" "${group}"; then
            survived=$((survived + 1))
            if IFS= read -r row <"/proc/${pid}/stat" && IFS= read -r comm <"/proc/${pid}/comm"; then
                read -r -a fields <<<"${row##*) }"
                if [[ "${fields[2]}" == "${group}" &&
                    ( "${comm}" == yes || "${comm}" == taskset || "${comm}" == bash ) ]]; then
                    if ! kill -KILL "${pid}" 2>/dev/null; then :; fi
                fi
            fi
        fi
    done <"$1"
    STRESS_SURVIVED="${survived}"
}

@test "stress: cleanup stops workers that inherit ignored TERM" {
    local script
    export -f stress_record_worker stress_worker_alive
    script=$(cat <<'SCRIPT'
        exec 3>&-
        trap "" TERM
        source "$1/test/helper/interrupt_load.bash"
        trap 'interrupt_load_stop' EXIT
        interrupt_load_start
        workers=()
        declare -A seen=()
        [[ "${#INTERRUPT_LOAD_PIDS[@]}" -eq 4 ]] || exit 1
        for pid in "${INTERRUPT_LOAD_PIDS[@]}"; do
            [[ -z "${seen[${pid}]:-}" ]] || exit 1
            seen["${pid}"]=1
            worker=$(stress_record_worker "${pid}") || exit 1
            read -r worker_pid start group <<<"${worker}"
            stress_worker_alive "${worker_pid}" "${start}" "${group}" || exit 1
            workers+=("${worker}")
        done
        (
            sleep 2
            for worker in "${workers[@]}"; do
                read -r pid start group <<<"${worker}"
                if stress_worker_alive "${pid}" "${start}" "${group}"; then
                    printf "worker survived cleanup\n"
                    if IFS= read -r row <"/proc/${pid}/stat" && IFS= read -r comm <"/proc/${pid}/comm"; then
                        read -r -a fields <<<"${row##*) }"
                        if [[ "${fields[2]}" == "${group}" &&
                            ( "${comm}" == yes || "${comm}" == taskset || "${comm}" == bash ) ]]; then
                            if ! kill -KILL "${pid}" 2>/dev/null; then :; fi
                        fi
                    fi
                fi
            done
        ) &
        watchdog=$!
        first_rc=0; interrupt_load_stop || first_rc=$?
        watchdog_rc=0; wait "$watchdog" || watchdog_rc=$?
        second_rc=0; interrupt_load_stop || second_rc=$?
        [[ "${first_rc}" -eq 0 && "${watchdog_rc}" -eq 0 && "${second_rc}" -eq 0 ]]
SCRIPT
    )
    run timeout -k 3 15 bash -c "${script}" _ "${REPO_ROOT}"
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
    cat >"${bin}/chmod" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "${arg}" == */bash && -n "${STRESS_WORKERS:-}" ]]; then
        limit=$((SECONDS + 5))
        until [[ $(wc -l <"${STRESS_WORKERS}") -eq 4 ]]; do
            [[ "${SECONDS}" -lt "${limit}" ]] || exit 2
            sleep 0.01
        done
        printf 'forced stress fixture failure\n' >&2
        exit 1
    fi
done
exec /bin/chmod "$@"
STUB
    chmod +x "${bin}/sed" "${bin}/chmod"
    export PATH="${bin}:${PATH}"
}

prepare_worker_recording() {
    export STRESS_WORKERS="${BATS_TEST_TMPDIR}/workers"
    export STRESS_TASKSET
    STRESS_TASKSET=$(command -v taskset)
    cat >"${BATS_TEST_TMPDIR}/failure-bin/taskset" <<'STUB'
#!/usr/bin/env bash
exec 3>&-
IFS= read -r row <"/proc/${BASHPID}/stat"
read -r -a fields <<<"${row##*) }"
printf '%s %s %s\n' "${BASHPID}" "${fields[19]}" "${fields[2]}" >>"${STRESS_WORKERS}"
exec "${STRESS_TASKSET}" "$@"
STUB
    /bin/chmod +x "${BATS_TEST_TMPDIR}/failure-bin/taskset"
}

# Each filter names one actual case, including the timeout descendant repro.
stress_case() {
    case "$1" in
        verify_run) STRESS_SPEC=verify_run_signal; STRESS_FILTER='^verify_run: HUP under CPU load always finishes before cleanup$' ;;
        realbox) STRESS_SPEC=verify_realbox; STRESS_FILTER='^5.1: group HUP under CPU load finishes before cleanup during assemble and bench$' ;;
        timeout) STRESS_SPEC=verify_realbox; STRESS_FILTER='^timeout cleanup: TERM-ignoring just descendant under CPU load$' ;;
    esac
}

@test "stress: CPU repro cases skip unless explicitly enabled" {
    local case_name value
    prepare_stress_failure
    prepare_worker_recording
    for case_name in verify_run realbox timeout; do
        stress_case "${case_name}"
        for value in unset 0; do
            : >"${STRESS_WORKERS}"
            if [[ "${value}" == unset ]]; then
                run timeout -k 3 60 env -u WORKTOOL_STRESS bats --formatter tap --filter "${STRESS_FILTER}" \
                    "${BATS_TEST_DIRNAME}/${STRESS_SPEC}_spec.bats"
            else
                run timeout -k 3 60 env WORKTOOL_STRESS="${value}" bats --formatter tap --filter "${STRESS_FILTER}" \
                    "${BATS_TEST_DIRNAME}/${STRESS_SPEC}_spec.bats"
            fi
            stress_check_workers "${STRESS_WORKERS}"
            assert_equal "${STRESS_SURVIVED}" 0
            assert_equal "$(wc -l <"${STRESS_WORKERS}")" 0
            assert_success
            assert_line '1..1'
            assert_output --partial '# skip set WORKTOOL_STRESS=1 to run CPU repro'
            refute_output --partial 'forced stress fixture failure'
        done
    done
}

@test "stress: enabled failing CPU repro cases leave no load workers" {
    local case_name workers="${BATS_TEST_TMPDIR}/workers"
    prepare_stress_failure
    prepare_worker_recording
    cat >"${BATS_TEST_TMPDIR}/failure-bin/sed" <<'STUB'
#!/usr/bin/env bash
limit=$((SECONDS + 5))
until [[ $(wc -l <"${STRESS_WORKERS}") -eq 4 ]]; do
    [[ "${SECONDS}" -lt "${limit}" ]] || exit 2
    sleep 0.01
done
printf 'forced stress fixture failure\n' >&2
exit 1
STUB
    /bin/chmod +x "${BATS_TEST_TMPDIR}/failure-bin/taskset"
    for case_name in verify_run realbox timeout; do
        stress_case "${case_name}"
        : >"${workers}"
        run timeout -k 3 60 env WORKTOOL_STRESS=1 bats --formatter tap --filter "${STRESS_FILTER}" \
            "${BATS_TEST_DIRNAME}/${STRESS_SPEC}_spec.bats"
        stress_check_workers "${workers}"
        assert_failure
        [[ "${status}" -ne 124 && "${status}" -ne 137 ]]
        assert_line '1..1'
        assert_output --partial 'forced stress fixture failure'
        refute_output --partial '# skip'
        assert_equal "$(wc -l <"${workers}")" 4
        assert_equal "${STRESS_SURVIVED}" 0
    done
}
