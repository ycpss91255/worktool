#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    export SIGNAL_STATE="${BATS_TEST_TMPDIR}"
    cat >"${SIGNAL_STATE}/child" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
trap 'sleep 0.2; echo finished >>"${SIGNAL_STATE}/events"; exit 0' INT TERM HUP
printf '%s\n' "$$" >"${SIGNAL_STATE}/child.pid"
touch "${SIGNAL_STATE}/ready"
sleep 3
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
_just() { (verify_run 10 "${SIGNAL_STATE}/child"); }
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
    sed -i '/^touch /i printf "%s\\n" "${WORKTOOL_TEST_RUN_ID}" >"${SIGNAL_STATE}/run-id"' "${SIGNAL_STATE}/just"
    sed -i 's@verify_run 10 "${SIGNAL_STATE}/child"@verify_run 10 just test@' "${SIGNAL_STATE}/caller"
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
    export PATH="${SIGNAL_STATE}:${PATH}"
    run signal_caller INT
    assert_success
    assert_line 'rc=130'
    [ -s "${SIGNAL_STATE}/run-id" ]
    run cat "${SIGNAL_STATE}/events"
    assert_output $'finished\ncontainers-cleaned\ncleanup'
}
