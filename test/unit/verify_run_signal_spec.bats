#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/interrupt_load"

setup() {
    export SIGNAL_STATE="${BATS_TEST_TMPDIR}"
    BASE_PATH="$(printenv PATH)"
    cat >"${SIGNAL_STATE}/child" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
stop_sleep() {
    if [[ -n "${!:-}" ]] && ! kill "$!" 2>/dev/null; then
        : # The background sleep may already have exited.
    fi
}
trap 'stop_sleep; sleep 0.2; echo finished >>"${SIGNAL_STATE}/events"; exit 0' INT TERM HUP
printf '%s\n' "$$" >"${SIGNAL_STATE}/child.pid"
printf '%s\n' "${WORKTOOL_TEST_RUN_ID:-}" >"${SIGNAL_STATE}/run-id"
touch "${SIGNAL_STATE}/ready"
sleep 3 & wait "$!"
echo finished >>"${SIGNAL_STATE}/events"
CHILD
    chmod +x "${SIGNAL_STATE}/child"
    cat >"${SIGNAL_STATE}/caller" <<'CALLER'
#!/usr/bin/env bash
set -euo pipefail
source "${LIB_DIR}/verify_run.sh"
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'echo cleanup >>"${SIGNAL_STATE}/events"' EXIT
_just() {
    (
        if [[ "${SIGNAL_TEST:-0}" == 1 ]]; then
            verify_run 10 just test
        else
            verify_run 10 "${SIGNAL_STATE}/child"
        fi
    )
}
_just
CALLER
}

signal_caller() {
    node "${BATS_TEST_DIRNAME}/fixture/verify_signal.js" "$1" bash "${SIGNAL_STATE}/caller"
}

assert_signal_cleanup() {
    run signal_caller "$1"
    assert_success
    assert_line "rc=$2"
    run cat "${SIGNAL_STATE}/events"
    assert_output $'finished\ncleanup'
    local pid
    read -r pid <"${SIGNAL_STATE}/child.pid"
    ! kill -0 "${pid}" 2>/dev/null
}

teardown() {
    interrupt_load_stop
    _1085_stop_blocked_group
    signal_child_stop
}

signal_child_stop() {
    local pid
    if [[ -f "${SIGNAL_STATE}/child.pid" ]]; then
        read -r pid <"${SIGNAL_STATE}/child.pid"
        if kill -0 "${pid}" 2>/dev/null; then
            kill -KILL "${pid}"
        fi
    fi
}

@test "verify_run: INT waits for the child before caller cleanup and exits 130" {
    assert_signal_cleanup INT 130
}

@test "verify_run: TERM waits for the child before caller cleanup and exits 143" {
    assert_signal_cleanup TERM 143
}

@test "verify_run: HUP waits for the child before caller cleanup and exits 129" {
    assert_signal_cleanup HUP 129
}

@test "verify_run: HUP under CPU load always finishes before cleanup" {
    [[ "${WORKTOOL_STRESS:-}" == 1 ]] || skip 'set WORKTOOL_STRESS=1 to run CPU repro'
    interrupt_load_start
    local attempt failures=0 trials=60
    sed -i "3i printf -v FORK_PAYLOAD \"%50000000s\" \"\"; taskset -pc \"\${INTERRUPT_LOAD_CPU}\" \"\$BASHPID\" >/dev/null; exec 9>>\"\${SIGNAL_STATE}/trace\"; BASH_XTRACEFD=9; set -x" "${SIGNAL_STATE}/child"
    for ((attempt=1; attempt<=trials; attempt++)); do
        rm -f "${SIGNAL_STATE}/ready" "${SIGNAL_STATE}/events"
        SIGNAL_DELAY_MAX_MS=10 SIGNAL_POLL_MS=1 run node "${BATS_TEST_DIRNAME}/fixture/verify_signal.js" HUP bash "${SIGNAL_STATE}/caller"
        if [[ "${status}" -ne 0 || "${output}" != *'rc=129'* ||
            "$(cat "${SIGNAL_STATE}/events")" != $'finished\ncleanup' ]]; then
            failures=$((failures + 1))
            printf '# attempt=%s status=%s output=%s events=%s\n' "${attempt}" "${status}" "${output}" "$(cat "${SIGNAL_STATE}/events")" >&3
        fi
        signal_child_stop
        if ((attempt % 10 == 0)); then
            printf '# verify_run HUP attempts=%s failures=%s\n' "${attempt}" "${failures}" >&3
        fi
    done
    interrupt_load_stop
    printf '# verify_run HUP load failures=%s/%s\n' "${failures}" "${trials}" >&3
    [ "${failures}" -eq 0 ]
}

_1085_prepare_ignoring_child() {
    cat >"${SIGNAL_STATE}/child" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
trap '' INT TERM HUP
printf '%s\n' "$$" >"${SIGNAL_STATE}/child.pid"
sleep 30 &
printf '%s\n' "$!" >"${SIGNAL_STATE}/sleep.pid"
awk '{print $22}' "/proc/$$/stat" >"${SIGNAL_STATE}/child.start"
awk '{print $22}' "/proc/$!/stat" >"${SIGNAL_STATE}/sleep.start"
touch "${SIGNAL_STATE}/ready"
wait "$!"
printf 'finished\n' >>"${SIGNAL_STATE}/events"
CHILD
    cat >"${SIGNAL_STATE}/kill-observer" <<'OBSERVER'
source "${LIB_DIR}/log.sh"
kill() {
    local rc=0 child_pid row child_group child_start expected_start verified=0
    local -a fields
    if [[ "$#" -eq 3 && "$1" == -KILL && "$2" == -- && "$3" == "-${monitor:-}" ]]; then
        if [[ "${SIGNAL_BLOCK_KILL:-0}" == 1 ]]; then
            printf '%s\n' "${monitor}" >"${SIGNAL_STATE}/blocked-group"
            return 1
        fi
        if [[ -f "${SIGNAL_STATE}/child.pid" && -f "${SIGNAL_STATE}/child.start" ]]; then
            read -r child_pid <"${SIGNAL_STATE}/child.pid"
            read -r expected_start <"${SIGNAL_STATE}/child.start"
            if [[ "${child_pid}" =~ ^[1-9][0-9]*$ && -r "/proc/${child_pid}/stat" ]] &&
                IFS= read -r row <"/proc/${child_pid}/stat"; then
                read -r -a fields <<<"${row##*) }"
                child_group="${fields[2]:-}" child_start="${fields[19]:-}"
                [[ "${child_group}" != "${monitor}" || "${child_start}" != "${expected_start}" ]] || verified=1
            fi
        fi
        builtin kill "$@" || rc=$?
        if [[ "${rc}" -eq 0 && "${verified}" -eq 1 ]]; then
            printf '%s\n' "${monitor}" >"${SIGNAL_STATE}/killed-group"
        fi
        return "${rc}"
    fi
    builtin kill "$@"
}
OBSERVER
    sed -i '/^source .*verify_run.sh/r '"${SIGNAL_STATE}"'/kill-observer' "${SIGNAL_STATE}/caller"
}

_1085_stop_blocked_group() {
    local pid group row state current file anchor=0 expected
    local -a fields
    [[ -f "${SIGNAL_STATE}/blocked-group" ]] || return 0
    read -r group <"${SIGNAL_STATE}/blocked-group"
    [[ "${group}" =~ ^[1-9][0-9]*$ ]] || return 1
    for file in "${SIGNAL_STATE}/child.pid" "${SIGNAL_STATE}/sleep.pid"; do
        [[ -f "${file}" ]] || return 1
        read -r pid <"${file}"
        [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
        if [[ -r "/proc/${pid}/stat" ]]; then
            IFS= read -r row <"/proc/${pid}/stat" || return 1
            read -r -a fields <<<"${row##*) }"
            state="${fields[0]:-}" current="${fields[2]:-}"
            read -r expected <"${file%.pid}.start" || return 1
            [[ "${current}" == "${group}" && "${fields[19]:-}" == "${expected}" ]] || return 1
            [[ "${state}" == Z || "${state}" == X ]] || anchor=1
        fi
    done
    if [[ "${anchor}" -eq 1 ]]; then
        kill -KILL -- "-${group}" || return 1
    fi
    _1085_group_stopped "${group}"
}

_1085_group_stopped() {
    local group="$1" rows attempt scan_rc
    [[ "${group}" =~ ^[1-9][0-9]*$ ]] || return 1
    for ((attempt=0; attempt<40; attempt++)); do
        rows="$(timeout -s KILL 1 ps -eo pgid=,stat=)" || return 1
        scan_rc=0
        awk -v group="${group}" '
            NF != 2 || $1 !~ /^[0-9]+$/ || $2 !~ /^[A-Za-z]/ { bad=1 }
            $1 == group && $2 !~ /^[ZX]/ { found=1 }
            END { if (bad || NR == 0) exit 2; exit found ? 1 : 0 }
        ' <<<"${rows}" || scan_rc=$?
        case "${scan_rc}" in 0) return 0 ;; 1) ;; *) return 1 ;; esac
        sleep 0.05 || return 1
    done
    return 1
}

_1085_monotonic_nanoseconds() {
    node -p 'process.hrtime.bigint().toString()'
}

_1085_within_grace() {
    (( $2 - $1 < 3000000000 ))
}

@test "verify_run: a signal-ignoring child is killed within the grace period" {
    _1085_prepare_ignoring_child
    local started ended
    started="$(_1085_monotonic_nanoseconds)"
    run signal_caller INT
    assert_success
    assert_line 'rc=130'
    ended="$(_1085_monotonic_nanoseconds)"
    _1085_within_grace "${started}" "${ended}"
    [ -s "${SIGNAL_STATE}/killed-group" ]
    local group
    read -r group <"${SIGNAL_STATE}/killed-group"
    _1085_group_stopped "${group}"
    [ "$(cat "${SIGNAL_STATE}/events")" = cleanup ]
    local pid
    read -r pid <"${SIGNAL_STATE}/child.pid"
    if kill -0 "${pid}" 2>/dev/null; then
        run grep -E '^[0-9]+ \([^)]*\) Z ' "/proc/${pid}/stat"
        assert_success
    fi
}

@test "verify_run: monotonic grace rejects a real interval over three seconds" {
    local started ended
    started="$(_1085_monotonic_nanoseconds)"
    sleep 3.1
    ended="$(_1085_monotonic_nanoseconds)"
    run _1085_within_grace "${started}" "${ended}"
    assert_failure
}

@test "verify_run: monotonic grace accepts under three seconds despite a controlled SECONDS jump" {
    local start_seconds started ended
    start_seconds="${SECONDS}"
    started="$(_1085_monotonic_nanoseconds)"
    SECONDS=$((start_seconds + 3))
    ended="$(_1085_monotonic_nanoseconds)"
    (( SECONDS - start_seconds >= 3 ))
    run _1085_within_grace "${started}" "${ended}"
    assert_success
}

@test "verify_run: blocked group KILL cannot pass the interruption check" {
    _1085_prepare_ignoring_child
    SIGNAL_BLOCK_KILL=1 run signal_caller INT
    local driver_status="${status}" driver_output="${output}" group
    [ -s "${SIGNAL_STATE}/blocked-group" ]
    read -r group <"${SIGNAL_STATE}/blocked-group"
    run _1085_group_stopped "${group}"
    assert_failure
    _1085_stop_blocked_group
    [ "${driver_status}" -ne 0 ]
    [[ "${driver_output}" == *'timeout-phase=cleanup'* ]]
    [[ $'\n'"${driver_output}"$'\n' != *$'\nrc=130\n'* ]]
    [ ! -e "${SIGNAL_STATE}/killed-group" ]
}

@test "verify_run: interruption removes only this test run's labelled containers" {
    cp "${SIGNAL_STATE}/child" "${SIGNAL_STATE}/just"
    cat >"${SIGNAL_STATE}/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    ps)
        [[ "$*" == "ps -aq --filter label=worktool.verify-run=$(cat "${SIGNAL_STATE}/run-id")" ]]
        echo owned-container
        ;;
    rm)
        [[ "$*" == 'rm -f -v owned-container' ]]
        echo containers-cleaned >>"${SIGNAL_STATE}/events"
        ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "${SIGNAL_STATE}/docker"
    export SIGNAL_TEST=1
    export PATH="${SIGNAL_STATE}:${PATH}"
    run signal_caller INT
    assert_success
    assert_line 'rc=130'
    [ -s "${SIGNAL_STATE}/run-id" ]
    run cat "${SIGNAL_STATE}/events"
    assert_output $'finished\ncontainers-cleaned\ncleanup'
}

@test "verify_run: deadline KILL is 124 while a command's own 137 is preserved" {
    run bash <<'PROBE'
source "${LIB_DIR}/verify_run.sh"
verify_run 5 bash -c 'exit 137'
PROBE
    assert_failure 137
    run bash <<'PROBE'
source "${LIB_DIR}/verify_run.sh"
export VERIFY_RUN_GUARD_DIR="${SIGNAL_STATE}"
verify_run 0.1 bash -c 'trap "" TERM; sleep 3'
PROBE
    assert_failure 124
    local pending=("${SIGNAL_STATE}"/verify-run.*)
    [ ! -e "${pending[0]}" ]
}

@test "verify_run: deadline with failed KILL and a live group retains the restore guard" {
    run bash <<'PROBE'
source "${LIB_DIR}/log.sh"
source "${LIB_DIR}/verify_run.sh"
export VERIFY_RUN_GUARD_DIR="${SIGNAL_STATE}"
# Inject a deadline and a group that cannot be killed.
timeout() { return 124; }
kill() { return 1; }
verify_group_running() { return 0; }
rc=0
verify_run 0.1 true || rc=$?
printf 'rc=%s\n' "${rc}"
pending=("${VERIFY_RUN_GUARD_DIR}"/verify-run.*)
[[ ! -d "${pending[0]}" ]] || echo guard-retained
if verify_restore_allowed; then echo restore-allowed; else echo restore-refused; fi
exit "${rc}"
PROBE
    assert_failure
    assert_line guard-retained
    assert_line restore-refused
    refute_line restore-allowed
    assert_output --partial 'post-KILL wait deadline exceeded'
}

@test "verify_run: failed or stuck container cleanup refuses restore" {
    cat >"${SIGNAL_STATE}/just" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
    cat >"${SIGNAL_STATE}/docker" <<'STUB'
#!/usr/bin/env bash
case "${CLEANUP_CASE}:$1" in
    list:ps) exit 1 ;;
    remove:ps) echo owned ;;
    remove:rm) exit 1 ;;
    stuck:ps) sleep 30 ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "${SIGNAL_STATE}/just" "${SIGNAL_STATE}/docker"
    local mode
    for mode in list remove stuck; do
        mkdir -p "${SIGNAL_STATE}/${mode}"
        run env CLEANUP_CASE="${mode}" VERIFY_RUN_GUARD_DIR="${SIGNAL_STATE}/${mode}" \
            PATH="${SIGNAL_STATE}:${BASE_PATH}" bash <<'PROBE'
source "${LIB_DIR}/log.sh"
source "${LIB_DIR}/verify_run.sh"
rc=0
verify_run 0.1 just test || rc=$?
printf 'rc=%s\n' "${rc}"
if verify_restore_allowed; then echo restore-allowed; else echo restore-refused; fi
exit "${rc}"
PROBE
        assert_failure 1
        assert_line restore-refused
        refute_line restore-allowed
        assert_output --partial 'container cleanup unconfirmed'
    done
}

@test "verify_run: signal after failed cleanup propagates and refuses restore" {
    cp "${SIGNAL_STATE}/child" "${SIGNAL_STATE}/just"
    printf '#!/usr/bin/env bash\nexit 1\n' >"${SIGNAL_STATE}/docker"
    chmod +x "${SIGNAL_STATE}/docker"
    cat >"${SIGNAL_STATE}/caller" <<'CALLER'
#!/usr/bin/env bash
set -euo pipefail
source "${LIB_DIR}/log.sh"
source "${LIB_DIR}/verify_run.sh"
trap 'exit 143' TERM
trap 'if verify_restore_allowed; then echo restore-allowed; else echo restore-refused; fi' EXIT
verify_run 10 just test
CALLER
    run env VERIFY_RUN_GUARD_DIR="${SIGNAL_STATE}" PATH="${SIGNAL_STATE}:${BASE_PATH}" \
        node "${BATS_TEST_DIRNAME}/fixture/verify_signal.js" TERM bash "${SIGNAL_STATE}/caller"
    assert_success
    assert_line 'rc=143'
    assert_line restore-refused
    refute_line restore-allowed
}

@test "verify_run: default TERM propagates instead of becoming caller failure 1" {
    cat >"${SIGNAL_STATE}/caller" <<'CALLER'
#!/usr/bin/env bash
set -euo pipefail
source "${LIB_DIR}/verify_run.sh"
if verify_run 10 "${SIGNAL_STATE}/child"; then
    exit 0
else
    exit 1
fi
CALLER
    run signal_caller TERM
    assert_success
    assert_line 'rc=143'
    run cat "${SIGNAL_STATE}/events"
    assert_output finished
    local pid
    read -r pid <"${SIGNAL_STATE}/child.pid"
    run kill -0 "${pid}"
    assert_failure 1
}

@test "verify_stop_group: a group still observable after KILL fails within a deadline" {
    run timeout --kill-after=1 4 bash <<'PROBE'
source "${LIB_DIR}/log.sh"
source "${LIB_DIR}/verify_run.sh"
# Model a kernel group that remains observable even after KILL.
kill() { return 0; }
verify_group_running() { return 0; }
verify_stop_group 999999 TERM
PROBE
    assert_failure 1
    assert_output --partial 'verify_stop_group: post-KILL wait deadline exceeded (pgid=999999)'
}

@test "verify_run: real interruption over the grace limit is rejected" {
    local tree="${BATS_TEST_TMPDIR}/slow-case"
    mkdir -p "${tree}/test/unit"
    ln -s "${REPO_ROOT}/test/helper" "${tree}/test/helper"
    ln -s "${REPO_ROOT}/test/unit/fixture" "${tree}/test/unit/fixture"
    cp "${BATS_TEST_FILENAME}" "${tree}/test/unit/verify_run_signal_spec.bats"
    sed -i '/^signal_caller() {$/a\    sleep 3.1' "${tree}/test/unit/verify_run_signal_spec.bats"
    run bats --filter '^verify_run: a signal-ignoring child is killed within the grace period$' "${tree}/test/unit/verify_run_signal_spec.bats"
    assert_failure
    assert_output --partial "_1085_within_grace \"\${started}\" \"\${ended}\""
}
