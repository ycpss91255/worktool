#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    export SIGNAL_STATE="${BATS_TEST_TMPDIR}"
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
    load "${BATS_TEST_DIRNAME}/../helper/interrupt_load"
    interrupt_load_start
    local attempt failures=0 trials=60
    sed -i '3i printf -v FORK_PAYLOAD "%50000000s" ""; taskset -pc "${INTERRUPT_LOAD_CPU}" "$BASHPID" >/dev/null; exec 9>>"${SIGNAL_STATE}/trace"; BASH_XTRACEFD=9; set -x' "${SIGNAL_STATE}/child"
    sed -e 's/}, 10);/}, 1);/' -e "s/process.kill(-p.pid, 'SIG' + process.argv\[2\]);/setTimeout(() => process.kill(-p.pid, 'SIG' + process.argv[2]), Math.floor(Math.random() * 10));/" \
        "${BATS_TEST_DIRNAME}/fixture/verify_signal.js" >"${SIGNAL_STATE}/signal.js"
    for ((attempt=1; attempt<=trials; attempt++)); do
        rm -f "${SIGNAL_STATE}/ready" "${SIGNAL_STATE}/events"
        run node "${SIGNAL_STATE}/signal.js" HUP bash "${SIGNAL_STATE}/caller"
        if [[ "${status}" -ne 0 || "${output}" != *'rc=129'* ||
            "$(cat "${SIGNAL_STATE}/events")" != $'finished\ncleanup' ]]; then
            failures=$((failures + 1))
            printf '# attempt=%s status=%s output=%s events=%s\n' "${attempt}" "${status}" "${output}" "$(cat "${SIGNAL_STATE}/events")" >&3
        fi
        teardown
        if ((attempt % 10 == 0)); then
            printf '# verify_run HUP attempts=%s failures=%s\n' "${attempt}" "${failures}" >&3
        fi
    done
    interrupt_load_stop
    printf '# verify_run HUP load failures=%s/%s\n' "${failures}" "${trials}" >&3
    [ "${failures}" -eq 0 ]
}

@test "verify_run: a signal-ignoring child is killed within the grace period" {
    sed -i "s/^trap .*/trap '' INT TERM HUP/" "${SIGNAL_STATE}/child"
    local start="${SECONDS}"
    run signal_caller INT
    assert_success
    assert_line 'rc=130'
    [ "$((SECONDS - start))" -lt 3 ]
    [ "$(cat "${SIGNAL_STATE}/events")" = cleanup ]
    local pid
    read -r pid <"${SIGNAL_STATE}/child.pid"
    if kill -0 "${pid}" 2>/dev/null; then
        run grep -E '^[0-9]+ \([^)]*\) Z ' "/proc/${pid}/stat"
        assert_success
    fi
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
verify_run 0.1 bash -c 'trap "" TERM; sleep 3'
PROBE
    assert_failure 124
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
