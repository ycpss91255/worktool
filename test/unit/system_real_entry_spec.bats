#!/usr/bin/env bats
# test/unit/system_real_entry_spec.bats - script/ci/system-real-entry.sh:
# every engine call in the dockerd wait loop and the cleanup trap is bounded
# (M2 review, codex non-blocking finding: a hung daemon could wedge a local
# run past the runner's own deadlines)
#
# WHAT THIS PROVES
#   With a docker CLI that hangs (never answers), `_wait_dockerd` still gives
#   up at its own deadline - WORKTOOL_DOCKERD_READY_TIMEOUT is authoritative,
#   a hung probe cannot push the loop past it - and `_cleanup` still finishes
#   and stops the daemon, instead of blocking until an outer job timeout
#   kills the runner. With a responsive CLI the same functions behave
#   normally (ready / leftover box removed through distrobox rm + docker rm).
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

load "${BATS_TEST_DIRNAME}/../helper/common"

# Outer safety net (seconds): far above every bound the entry script applies
# in these scenarios, so 124 here means "the script hung".
OUTER_TIMEOUT=45

setup() {
    ENTRY="${REPO_ROOT}/script/ci/system-real-entry.sh"
    DRIVER="${REPO_ROOT}/test/unit/fixture/entry_driver.sh"
    FAKEBIN="${BATS_TEST_TMPDIR}/bin"
    FAKE_LOG="${BATS_TEST_TMPDIR}/calls.log"
    PIDFILE="${BATS_TEST_TMPDIR}/dockerd.pid"
    mkdir -p "${FAKEBIN}"
    : >"${FAKE_LOG}"

    # Fake docker: records every call; FAKE_MODE=hang never returns,
    # otherwise answers info / ps / rm like an idle engine (FAKE_DEV=1 makes
    # `ps` list a leftover box named dev).
    cat >"${FAKEBIN}/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"${FAKE_LOG}"
[[ "${FAKE_MODE:-}" == "hang" ]] && exec sleep 1000
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
# pending exit status `_cleanup` must read from `$?` (default 0).
_with_entry() {
    run timeout "${OUTER_TIMEOUT}" \
        bash "${DRIVER}" "${ENTRY}" "${PIDFILE}" "${2:-live}" "${3:-0}" "$1"
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
    assert_output --partial "[system-real] stopping nested dockerd"
    run cat "${FAKE_LOG}"
    assert_line "distrobox rm -f dev"
    assert_line "docker rm -f dev"
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
