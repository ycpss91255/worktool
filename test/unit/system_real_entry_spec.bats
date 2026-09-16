#!/usr/bin/env bats
# test/unit/system_real_entry_spec.bats - script/test/system-real-entry.sh:
# every engine call in the dockerd wait loop and the cleanup trap is bounded
# (M2 review, codex non-blocking finding: a hung daemon could wedge a local
# run past the runner's own deadlines), the readiness deadline is
# authoritative on the SUCCESS path too, the timeouts are validated, and the
# cleanup's leftover count is honest (codex re-verification of PR #20).
#
# WHAT THIS PROVES
#   With a docker CLI that hangs (never answers), `_wait_dockerd` still gives
#   up at its own deadline - WORKTOOL_DOCKERD_READY_TIMEOUT is authoritative,
#   a hung probe cannot push the loop past it - and `_cleanup` still finishes
#   and stops the daemon, instead of blocking until an outer job timeout
#   kills the runner. With a responsive CLI the same functions behave
#   normally (ready / leftover box removed through distrobox rm + docker rm).
#   When the readiness probe answers but the engine-details query after it
#   hangs, the wait still ends within the SAME deadline (+ kill grace): the
#   details are bounded by what is left of the readiness budget and skipped
#   outright when it is spent. The two overridable timeouts are refused
#   before dockerd starts unless they are positive integers (`timeout 0`
#   would mean "no bound"). When the cleanup's `docker ps` hangs, the
#   leftover count says "unknown (query failed)" instead of a fake 0.
#
# HOW
#   test/unit/fixture/entry_driver.sh sources the entry script (its main()
#   is guarded), installs a background `sleep` as the stand-in dockerd
#   (DOCKERD_PID) and calls one function, with a FAKE `docker` / `distrobox`
#   first on PATH. Each run is wrapped in an OUTER `timeout` far above the
#   script's own bounds, so a hang shows up as exit 124 rather than as a
#   stuck test. No daemon, no privileges: pure bash. Environment for the
#   script and the fakes is passed as call-prefix assignments
#   (`FAKE_MODE=hang _with_entry ...`), which bash exports to the child.
#   FAKE_MODE selects WHAT hangs: `hang` (every call), `hang-format` (only
#   `info --format`, the post-readiness details query), `hang-ps` (only
#   `ps`, the cleanup queries).

load "${BATS_TEST_DIRNAME}/../helper/common"

# Outer safety net (seconds): far above every bound the entry script applies
# in these scenarios, so 124 here means "the script hung".
OUTER_TIMEOUT=45

# Mirrors KILL_GRACE in the entry script: the SIGTERM -> SIGKILL escalation
# of `timeout -k`. The documented worst case of `_wait_dockerd` is
# WORKTOOL_DOCKERD_READY_TIMEOUT + KILL_GRACE + 1s on both paths.
KILL_GRACE=5

setup() {
    ENTRY="${REPO_ROOT}/script/test/system-real-entry.sh"
    DRIVER="${REPO_ROOT}/test/unit/fixture/entry_driver.sh"
    FAKEBIN="${BATS_TEST_TMPDIR}/bin"
    FAKE_LOG="${BATS_TEST_TMPDIR}/calls.log"
    PIDFILE="${BATS_TEST_TMPDIR}/dockerd.pid"
    mkdir -p "${FAKEBIN}"
    : >"${FAKE_LOG}"

    # Fake docker: records every call; FAKE_MODE=hang never returns,
    # hang-format hangs only `info --format ...` (the details query after a
    # successful readiness probe), hang-ps hangs only `ps` (the cleanup
    # queries); otherwise answers info / ps / rm like an idle engine
    # (FAKE_DEV=1 makes `ps` list a leftover box named dev).
    cat >"${FAKEBIN}/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"${FAKE_LOG}"
case "${FAKE_MODE:-}" in
    hang)        exec sleep 1000 ;;
    hang-format) [[ "${1:-}" == info && "$*" == *--format* ]] && exec sleep 1000 ;;
    hang-ps)     [[ "${1:-}" == ps ]] && exec sleep 1000 ;;
    # First probe fails at once; every later probe ignores SIGTERM and
    # hangs, so `timeout` has to escalate to SIGKILL after its kill grace.
    fail-then-hang-ignore-term)
        if [[ "${1:-}" == info ]]; then
            if [[ ! -f "${FAKE_LOG}.failed-once" ]]; then
                : >"${FAKE_LOG}.failed-once"; exit 1
            fi
            # Record the ignored SIGTERM: the only way this process ends is
            # the SIGKILL `timeout -k` sends KILL_GRACE later.
            trap 'printf "fake: SIGTERM ignored\n" >>"${FAKE_LOG}"' TERM
            while :; do sleep 1; done
        fi ;;
esac
case "${1:-}" in
    info) exit 0 ;;
    ps)   [[ -n "${FAKE_DEV:-}" ]] && printf 'dev\n'; exit 0 ;;
    rm)   exit 0 ;;
    *)    exit 1 ;;
esac
EOF
    # Fake distrobox: records its arguments and succeeds.
    cat >"${FAKEBIN}/distrobox" <<'EOF'
#!/usr/bin/env bash
printf 'distrobox %s\n' "$*" >>"${FAKE_LOG}"
exit 0
EOF
    chmod +x "${FAKEBIN}/docker" "${FAKEBIN}/distrobox"
    PATH="${FAKEBIN}:${PATH}"

    # FAKE_LOG reaches the fakes through the environment; the daemon log is
    # kept under the test tmpdir rather than /var/log.
    export FAKE_LOG
    export WORKTOOL_DOCKERD_LOG="${BATS_TEST_TMPDIR}/dockerd.log"
}

teardown() {
    # The stand-in dockerd survives a `_die` path; never leak it.
    if [[ -f "${PIDFILE}" ]]; then
        kill -KILL "$(cat "${PIDFILE}")" 2>/dev/null || true
    fi
}

# Run entry-script function $1 through the driver under the outer timeout.
# $2 = stand-in dockerd mode (live / dead / none, default live), $3 = the
# pending exit status `_cleanup` must read from `$?` (default 0); any
# further arguments are passed to the function.
_with_entry() {
    local _fn="$1" _stand_in="${2:-live}" _rc="${3:-0}"
    shift "$(( $# < 3 ? $# : 3 ))"
    run timeout "${OUTER_TIMEOUT}" \
        bash "${DRIVER}" "${ENTRY}" "${PIDFILE}" "${_stand_in}" "${_rc}" "${_fn}" "$@"
}

# --- _wait_dockerd -----------------------------------------------------------

@test "_wait_dockerd gives up at WORKTOOL_DOCKERD_READY_TIMEOUT when docker info hangs" {
    local _t0="${SECONDS}"
    FAKE_MODE=hang WORKTOOL_DOCKERD_READY_TIMEOUT=3 WORKTOOL_DOCKER_CALL_TIMEOUT=2 \
        _with_entry _wait_dockerd
    # 124 would mean the outer timeout had to kill a wedged loop.
    assert_failure 1
    assert_output --partial "[system-real] ERROR: dockerd not ready after 3s"
    # The deadline is authoritative: 3s budget, at most one bounded probe
    # past it, never anywhere near the outer timeout.
    assert [ "$(( SECONDS - _t0 ))" -lt 15 ]
}

@test "_wait_dockerd returns 0 and reports readiness when docker info answers" {
    WORKTOOL_DOCKERD_READY_TIMEOUT=10 _with_entry _wait_dockerd
    assert_success
    assert_output --partial "[system-real] dockerd ready after"
    assert [ "$(grep -c '^docker info' "${FAKE_LOG}")" -ge 1 ]
    # The engine details query ran (and had budget to).
    run cat "${FAKE_LOG}"
    assert_line --regexp '^docker info --format '
}

@test "_wait_dockerd stays within deadline + kill grace when the probe answers but the details query hangs" {
    local _t0="${SECONDS}" _ready=3
    # Per-call budget (20s) deliberately LARGER than the readiness budget
    # (3s): if the details query were bounded by the per-call budget alone,
    # this run would take ~20s, well past deadline + grace.
    FAKE_MODE=hang-format WORKTOOL_DOCKERD_READY_TIMEOUT="${_ready}" \
        WORKTOOL_DOCKER_CALL_TIMEOUT=20 _with_entry _wait_dockerd
    local _elapsed=$(( SECONDS - _t0 ))
    # The readiness deadline is authoritative on the success path too.
    assert [ "${_elapsed}" -lt "$(( _ready + KILL_GRACE + 1 ))" ]
    # Readiness was decided by the probe: the hung details query is a
    # nicety and never turns a ready daemon into a failure.
    assert_success
    assert_output --partial "[system-real] dockerd ready after"
    assert_output --partial "[system-real] engine details unavailable"
}

@test "_wait_dockerd never sleeps past an exhausted deadline: a failed probe followed by a TERM-ignoring hang ends within deadline + kill grace + 1s" {
    local _ready=3
    # Timeline with per-call budget (20s) > readiness budget (3s):
    # t=0 probe fails fast -> sleep 1 -> t=1 probe gets the remaining 2s,
    # ignores SIGTERM at t=3, is SIGKILLed at t=3+KILL_GRACE=8. The loop must
    # stop right there: one more unconditional `sleep 1` would land past
    # the documented worst case (deadline + KILL_GRACE + 1s = 9s).
    local _t0="${EPOCHREALTIME}"
    FAKE_MODE=fail-then-hang-ignore-term WORKTOOL_DOCKERD_READY_TIMEOUT="${_ready}" \
        WORKTOOL_DOCKER_CALL_TIMEOUT=20 _with_entry _wait_dockerd
    local _elapsed_ms
    _elapsed_ms="$(awk -v a="${_t0}" -v b="${EPOCHREALTIME}" 'BEGIN { printf "%d", (b - a) * 1000 }')"
    assert_failure 1
    assert_output --partial "[system-real] ERROR: dockerd not ready after ${_ready}s"
    # Both probes ran: the fast failure and the one that had to be killed.
    assert [ "$(grep -c '^docker info' "${FAKE_LOG}")" -eq 2 ]
    # The second probe saw SIGTERM and ignored it, yet the run ended: only
    # the SIGKILL escalation explains that.
    assert [ "$(grep -c '^fake: SIGTERM ignored' "${FAKE_LOG}")" -ge 1 ]
    assert [ "${_elapsed_ms}" -le "$(( (_ready + KILL_GRACE + 1) * 1000 ))" ]
}

@test "_engine_details skips the query (and says so) when the readiness budget is already spent" {
    # Deadline 0 in SECONDS terms: nothing left of the readiness budget.
    _with_entry _engine_details none 0 0
    assert_success
    assert_output --partial "[system-real] engine details skipped (readiness budget spent)"
    run cat "${FAKE_LOG}"
    assert_output ""
}

# --- _check_timeouts ---------------------------------------------------------

@test "_check_timeouts refuses WORKTOOL_DOCKER_CALL_TIMEOUT=0 (timeout 0 would mean no bound)" {
    WORKTOOL_DOCKER_CALL_TIMEOUT=0 _with_entry _check_timeouts none
    assert_failure 1
    assert_output --partial "[system-real] ERROR: WORKTOOL_DOCKER_CALL_TIMEOUT must be a positive integer (seconds), got '0'"
}

@test "_check_timeouts refuses WORKTOOL_DOCKERD_READY_TIMEOUT=abc" {
    WORKTOOL_DOCKERD_READY_TIMEOUT=abc _with_entry _check_timeouts none
    assert_failure 1
    assert_output --partial "[system-real] ERROR: WORKTOOL_DOCKERD_READY_TIMEOUT must be a positive integer (seconds), got 'abc'"
}

@test "_check_timeouts refuses negative and zero readiness timeouts" {
    WORKTOOL_DOCKERD_READY_TIMEOUT=-5 _with_entry _check_timeouts none
    assert_failure 1
    assert_output --partial "WORKTOOL_DOCKERD_READY_TIMEOUT must be a positive integer (seconds), got '-5'"

    WORKTOOL_DOCKERD_READY_TIMEOUT=0 _with_entry _check_timeouts none
    assert_failure 1
    assert_output --partial "WORKTOOL_DOCKERD_READY_TIMEOUT must be a positive integer (seconds), got '0'"
}

@test "_check_timeouts accepts valid positive integers (and the defaults)" {
    WORKTOOL_DOCKERD_READY_TIMEOUT=30 WORKTOOL_DOCKER_CALL_TIMEOUT=7 \
        _with_entry _check_timeouts none
    assert_success
    assert_output ""

    _with_entry _check_timeouts none
    assert_success
    assert_output ""
}

@test "entry refuses an invalid timeout at start, before any preflight or dockerd" {
    # The real entry (main), not the driver: the check must be wired in
    # front of everything else. Any later step would fail differently here
    # (no --privileged, no dind helpers), so the message proves the order.
    WORKTOOL_DOCKER_CALL_TIMEOUT=0 run timeout "${OUTER_TIMEOUT}" bash "${ENTRY}"
    assert_failure 1
    assert_output --partial "[system-real] ERROR: WORKTOOL_DOCKER_CALL_TIMEOUT must be a positive integer (seconds), got '0'"
    refute_output --partial "starting nested dockerd"
    refute_output --partial "must run as root"
    refute_output --partial "CAP_SYS_ADMIN"
}

@test "_wait_dockerd fails at once when the daemon process is already gone" {
    local _t0="${SECONDS}"
    FAKE_MODE=hang WORKTOOL_DOCKERD_READY_TIMEOUT=10 _with_entry _wait_dockerd dead
    assert_failure 1
    assert_output --partial "[system-real] ERROR: dockerd exited before becoming ready"
    assert [ "$(( SECONDS - _t0 ))" -lt 10 ]
}

# --- _cleanup ------------------------------------------------------------------

@test "_cleanup finishes and stops the daemon when docker info hangs" {
    local _t0="${SECONDS}"
    FAKE_MODE=hang WORKTOOL_DOCKER_CALL_TIMEOUT=2 _with_entry _cleanup
    assert_success
    assert_output --partial "[system-real] stopping nested dockerd"
    assert [ "$(( SECONDS - _t0 ))" -lt 20 ]
    # The stand-in dockerd was actually stopped.
    run kill -0 "$(cat "${PIDFILE}")"
    assert_failure
}

@test "_cleanup removes a leftover dev box through bounded distrobox rm + docker rm and keeps the pending status" {
    FAKE_DEV=1 _with_entry _cleanup live 3
    assert_failure 3
    assert_output --partial "cleanup: box 'dev' still present - removing"
    # The fake `ps -aq` lists the one leftover: a real numeric count.
    assert_output --partial "cleanup: containers left in the nested daemon: 1"
    assert_output --partial "[system-real] stopping nested dockerd"
    run cat "${FAKE_LOG}"
    assert_line "distrobox rm -f dev"
    assert_line "docker rm -f dev"
    run kill -0 "$(cat "${PIDFILE}")"
    assert_failure
}

@test "_cleanup reports the leftover count as unknown (never 0) when docker ps hangs, and still finishes" {
    local _t0="${SECONDS}"
    FAKE_MODE=hang-ps WORKTOOL_DOCKER_CALL_TIMEOUT=2 _with_entry _cleanup
    assert_success
    assert_output --partial "cleanup: containers left in the nested daemon: unknown (query failed)"
    refute_output --partial "containers left in the nested daemon: 0"
    assert_output --partial "[system-real] stopping nested dockerd"
    assert [ "$(( SECONDS - _t0 ))" -lt 20 ]
    run kill -0 "$(cat "${PIDFILE}")"
    assert_failure
}

@test "_cleanup touches neither the engine nor a daemon when none was started" {
    _with_entry _cleanup none
    assert_success
    refute_output --partial "cleanup:"
    refute_output --partial "stopping nested dockerd"
    run cat "${FAKE_LOG}"
    assert_output ""
}
