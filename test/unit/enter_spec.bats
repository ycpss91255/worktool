#!/usr/bin/env bats
# test/unit/enter_spec.bats - script/box/enter.sh: the in-box entry wrapper
# with observable first-launch progress (M3, issue #180)
#
# Written test-first (RED) before the script exists, then the script is
# implemented to pass (GREEN).
#
# Contract under test (issue #180 '## 決定'):
#   - First initialisation is detected with `docker inspect` State.StartedAt
#     at its zero value (0001-01-01...). Any other answer - a started box,
#     no such box, no docker at all - hands over to `<distrobox> enter <box>
#     [-- cmd...]` at once, with no notice and no extra engine call.
#   - On a first launch, stderr first says that the first start installs
#     packages and can take several minutes, gives `docker logs -f <box>`
#     and the host log path ${XDG_CACHE_HOME:-~/.cache}/worktool/<box>-init.log;
#     then one progress line per interval (10 s by default): stage +
#     elapsed time + the latest init output line. The log file holds the
#     full init output.
#   - A timeout (15 min by default; --timeout / WORKTOOL_INIT_TIMEOUT), an
#     `Error:` line from distrobox-init, a container that stops, or a
#     failing `docker start` print the reason, the log path, the last 20
#     log lines and the recovery command (`distrobox rm -f <box>`, then a
#     new terminal), and exit 1 - the box is never stopped or removed.
#   - The background log follower is gone after success, failure, timeout
#     and an interrupt (trap).
#   - On success it prints that initialisation is complete and hands over
#     to `<distrobox> enter <box> [-- cmd...]`.
#   - The script owns its CLI: --help exit 0 (after parsing the whole
#     command line), `enter.sh: unknown option '<x>' (see --help)` exit 2.
#
# The engine and distrobox are fakes (test/helper/enter_fake.bash); every
# case runs under a throwaway HOME. The progress interval is shortened with
# WORKTOOL_INIT_INTERVAL so a "long" initialisation takes seconds.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/enter_fake"

bats_require_minimum_version 1.5.0

setup() {
    ENTER="${REPO_ROOT}/script/box/enter.sh"
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CACHE_HOME WORKTOOL_INIT_TIMEOUT WORKTOOL_INIT_INTERVAL
    mkdir -p "${HOME}"
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    enter_fake_install "${FAKE_BIN}"
    DISTROBOX="${FAKE_BIN}/distrobox"
    export FAKE_DOCKER_CALLS="${BATS_TEST_TMPDIR}/docker.calls"
    export FAKE_DISTROBOX_CALLS="${BATS_TEST_TMPDIR}/distrobox.calls"
    export FAKE_LOGS_PIDFILE="${BATS_TEST_TMPDIR}/logs.pid"
    export FAKE_LOGS_SCRIPT="${BATS_TEST_TMPDIR}/logs.script"
    export FAKE_STARTED_AT="${FAKE_ZERO_STARTED_AT}"
    PATH="${FAKE_BIN}:${PATH}"
    export PATH
    INIT_LOG="${HOME}/.cache/worktool/dev-init.log"
}

# A leaked follower would also hold bats' fd 3 open; never leave one behind.
teardown() {
    if enter_fake_logs_alive; then
        kill "$(cat "${FAKE_LOGS_PIDFILE}")" 2>/dev/null || true
    fi
}

# A healthy first init: a stage, a few package lines a second apart, done.
_long_init_script() {
    enter_fake_logs \
        '0|+ set -o errexit' \
        '0|distrobox: Installing basic packages...' \
        '1|Unpacking pkg-1' \
        '1|Unpacking pkg-2' \
        '1|Unpacking pkg-3' \
        '1|Setting up pkg-4' \
        '1|distrobox: Setting up read-only mounts...' \
        '0|container_setup_done'
}

# Run the wrapper with a 1 s progress interval.
_enter() {
    WORKTOOL_INIT_INTERVAL=1 run "${ENTER}" "$@"
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# --- CLI -----------------------------------------------------------------------

@test "--help and -h print the usage and exit 0 without touching the engine" {
    run "${ENTER}" --help
    assert_success
    assert_line --partial "Usage: enter.sh"
    assert_output --partial "--timeout"
    run "${ENTER}" -h
    assert_success
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

@test "an unknown option is refused by the script (exit 2), even after --help" {
    run "${ENTER}" --bogus
    assert_failure 2
    assert_output "enter.sh: unknown option '--bogus' (see --help)"
    run "${ENTER}" --help --bogus
    assert_failure 2
    assert_output "enter.sh: unknown option '--bogus' (see --help)"
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

@test "invalid values are refused with exit 2 before anything runs" {
    run "${ENTER}" --timeout 0
    assert_failure 2
    assert_output --partial "enter.sh: invalid value '0' for --timeout"
    run "${ENTER}" --timeout abc
    assert_failure 2
    run "${ENTER}" --box
    assert_failure 2
    assert_output "enter.sh: --box requires a value (see --help)"
    run "${ENTER}" --box -x
    assert_failure 2
    run "${ENTER}" --distrobox relative/distrobox
    assert_failure 2
    assert_output --partial "invalid value 'relative/distrobox' for --distrobox"
    WORKTOOL_INIT_TIMEOUT=soon run "${ENTER}" --distrobox "${DISTROBOX}"
    assert_failure 2
    assert_output --partial "invalid value 'soon' for WORKTOOL_INIT_TIMEOUT"
    WORKTOOL_INIT_INTERVAL=0 run "${ENTER}" --distrobox "${DISTROBOX}"
    assert_failure 2
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

@test "--box follows the container name rule [A-Za-z0-9][A-Za-z0-9_.-]*; anything else is exit 2" {
    local _name
    for _name in 'my box' $'dev\nwork' '.dev' '_dev' 'dev/work' 'dev;id' 'dév' ''; do
        run "${ENTER}" --distrobox "${DISTROBOX}" --box "${_name}"
        assert_failure 2
        assert_output --partial "enter.sh: invalid value '${_name}' for --box (expected a container name: [A-Za-z0-9][A-Za-z0-9_.-]*) (see --help)"
        run "${ENTER}" --distrobox "${DISTROBOX}" "--box=${_name}"
        assert_failure 2
    done
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
    FAKE_STARTED_AT='2026-01-01T00:00:00Z' run "${ENTER}" --distrobox "${DISTROBOX}" --box 'W0rk_1.b-x'
    assert_success
    assert_output "FAKE-DISTROBOX enter W0rk_1.b-x"
}

@test "no distrobox on PATH and no --distrobox: exit 1 with a readable error" {
    rm -f "${DISTROBOX}"
    PATH="${FAKE_BIN}:/usr/bin:/bin" run "${ENTER}"
    assert_failure 1
    assert_output --partial "[ERROR] distrobox: not found on PATH"
}

# --- not a first launch: straight hand-over ----------------------------------------

@test "an already started box hands over to distrobox enter at once, with no notice and no docker start" {
    export FAKE_STARTED_AT="2026-09-29T09:13:42.123456789Z"
    _enter --distrobox "${DISTROBOX}" -- tmux new -A -s main
    assert_success
    assert_line "FAKE-DISTROBOX enter dev -- tmux new -A -s main"
    refute_output --partial "first launch"
    run grep -c . "${FAKE_DOCKER_CALLS}"
    assert_output "1"
    run grep -F 'start' "${FAKE_DOCKER_CALLS}"
    assert_failure
}

@test "no such box (inspect fails) or no docker at all: hand over to distrobox, which reports it" {
    FAKE_INSPECT_RC=1 _enter --distrobox "${DISTROBOX}" --box work
    assert_success
    assert_line "FAKE-DISTROBOX enter work"
    refute_output --partial "first launch"
    rm -f "${FAKE_BIN}/docker"
    PATH="${FAKE_BIN}:/usr/bin:/bin" run "${ENTER}" --distrobox "${DISTROBOX}"
    assert_success
    assert_line "FAKE-DISTROBOX enter dev"
}

# ADR 0005 (invariant 2, single source): the default box name is not a
# second copy in enter.sh. It comes from `enter_default box` in lib/enter.sh,
# the source setup.sh uses too, so a fixture repo whose lib says `work` makes
# both the hand-over and --help follow it.
@test "the default box comes from lib/enter.sh enter_default, not a second copy in enter.sh (ADR 0005)" {
    local _fixture="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${_fixture}/script/box"
    cp -R "${REPO_ROOT}/lib" "${_fixture}/lib"
    cp "${ENTER}" "${_fixture}/script/box/enter.sh"
    sed -i "s|box)        printf 'dev\\\\n' ;;|box)        printf 'work\\\\n' ;;|" \
        "${_fixture}/lib/enter.sh"
    run bash -c 'source "$1" && enter_default box' _ "${_fixture}/lib/enter.sh"
    assert_output "work"
    FAKE_STARTED_AT="2026-09-29T09:13:42.123456789Z" WORKTOOL_INIT_INTERVAL=1 \
        run "${_fixture}/script/box/enter.sh" --distrobox "${DISTROBOX}"
    assert_success
    assert_line "FAKE-DISTROBOX enter work"
    run "${_fixture}/script/box/enter.sh" --help
    assert_success
    assert_output --partial "(default: work)"
    # No other copy anywhere in the help: not the word `dev` at all.
    refute_output --regexp '(^|[^[:alnum:]_])dev([^[:alnum:]_]|$)'
}

# --- first launch: notice, progress, log, hand-over -----------------------------

@test "first launch: a long initialisation keeps printing progress lines (stage + elapsed + latest line), then enters" {
    _long_init_script
    _enter --distrobox "${DISTROBOX}" -- tmux new -A -s main
    assert_success
    local _out="${output}" _n
    assert_line --partial "first launch of box 'dev'"
    assert_output --partial "can take several minutes"
    assert_output --partial "docker logs -f dev"
    assert_output --partial "${INIT_LOG}"
    # Not two static lines: one progress line per interval, and they change.
    _n="$(grep -c 'first launch: Installing basic packages\.\.\. - [0-9]*s elapsed - ' <<<"${_out}")"
    [[ "${_n}" -ge 3 ]] || fail "expected >= 3 progress lines, got ${_n}: ${_out}"
    _n="$(grep 's elapsed - ' <<<"${_out}" | sort -u | wc -l)"
    [[ "${_n}" -ge 3 ]] || fail "progress lines do not change: ${_out}"
    assert_line --regexp 'elapsed - Unpacking pkg-[0-9]$'
    # xtrace lines (`+ ...`) are not "output"; distrobox-enter drops them too.
    refute_line --partial 'elapsed - + set'
    assert_line --regexp 'first launch: initialisation complete after [0-9]+s'
    run cat "${FAKE_DISTROBOX_CALLS}"
    assert_output "enter dev -- tmux new -A -s main"
}

@test "first launch: the full init output is saved to the host log, under XDG_CACHE_HOME when set" {
    _long_init_script
    export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/xdg-cache"
    _enter --distrobox "${DISTROBOX}"
    assert_success
    local _log="${XDG_CACHE_HOME}/worktool/dev-init.log"
    assert_output --partial "${_log}"
    run cat "${_log}"
    assert_line "distrobox: Installing basic packages..."
    assert_line "Unpacking pkg-2"
    assert_line "container_setup_done"
    assert [ ! -e "${INIT_LOG}" ]
}

@test "first launch: docker start is issued once and the box is never stopped or removed" {
    _long_init_script
    _enter --distrobox "${DISTROBOX}"
    assert_success
    run grep -cx 'docker start dev' "${FAKE_DOCKER_CALLS}"
    assert_output "1"
    run grep -E '^docker (stop|rm|kill)' "${FAKE_DOCKER_CALLS}"
    assert_failure
}

# --- first launch: timeout and failures ---------------------------------------

@test "timeout: ends within its deadline, exit 1, with the reason, log path, last lines and recovery - never stuck" {
    enter_fake_logs '0|distrobox: Installing basic packages...' '0|Unpacking stuck-pkg'
    local _t0="${SECONDS}"
    _enter --distrobox "${DISTROBOX}" --timeout 3
    local _took=$((SECONDS - _t0))
    assert_failure 1
    [[ "${_took}" -lt 10 ]] || fail "took ${_took}s for a 3s timeout"
    assert_output --partial "[ERROR] first launch of box 'dev' failed: timed out after 3s"
    assert_line "[ERROR] init log: ${INIT_LOG}"
    assert_line "  | Unpacking stuck-pkg"
    assert_output --partial "distrobox rm -f dev"
    assert_output --partial "open a new terminal"
    assert_line --regexp 'first launch: Installing basic packages\.\.\. - [0-9]+s elapsed - Unpacking stuck-pkg'
    refute_output --partial "FAKE-DISTROBOX"
    run grep -E '^docker (stop|rm|kill)' "${FAKE_DOCKER_CALLS}"
    assert_failure
    run enter_fake_logs_alive
    assert_failure
}

@test "timeout: WORKTOOL_INIT_TIMEOUT overrides the default" {
    enter_fake_logs '0|distrobox: Installing basic packages...'
    WORKTOOL_INIT_TIMEOUT=2 _enter --distrobox "${DISTROBOX}"
    assert_failure 1
    assert_output --partial "timed out after 2s"
}

@test "failure: an Error: line from distrobox-init fails at once with the last 20 log lines" {
    local _i _lines=()
    for _i in $(seq -w 1 30); do _lines+=("0|line-${_i}"); done
    enter_fake_logs "${_lines[@]}" '0|Error: An error occurred'
    _enter --distrobox "${DISTROBOX}" --timeout 30
    assert_failure 1
    assert_output --partial "failed: distrobox-init reported: Error: An error occurred"
    assert_line "[ERROR] last 20 lines of the init log:"
    assert_line "  | line-12"
    assert_line "  | line-30"
    assert_line "  | Error: An error occurred"
    refute_line "  | line-11"
    assert_output --partial "distrobox rm -f dev"
    run enter_fake_logs_alive
    assert_failure
}

@test "failure: a container that stops during initialisation fails with exit 1" {
    enter_fake_logs '0|distrobox: Installing basic packages...'
    FAKE_RUNNING=false _enter --distrobox "${DISTROBOX}" --timeout 30
    assert_failure 1
    assert_output --partial "failed: the container stopped during initialisation"
    assert_output --partial "${INIT_LOG}"
    run enter_fake_logs_alive
    assert_failure
}

@test "failure: a log follower that dies early fails at once with its status, not a false timeout" {
    enter_fake_logs '0|distrobox: Installing basic packages...' \
        '0|permission denied while trying to connect to the Docker daemon socket'
    FAKE_LOGS_RC=1 _enter --distrobox "${DISTROBOX}" --timeout 30
    assert_failure 1
    assert_output --partial "failed: the log follower (docker logs -f dev) exited with status 1 before container_setup_done"
    assert_output --partial "  | permission denied while trying to connect"
    assert_output --partial "distrobox rm -f dev"
    refute_output --partial "timed out"
    refute_output --partial "FAKE-DISTROBOX"
}

@test "a follower that ends right after container_setup_done is still a success" {
    _long_init_script
    FAKE_LOGS_RC=0 _enter --distrobox "${DISTROBOX}"
    assert_success
    assert_output --partial "initialisation complete"
    assert_line "FAKE-DISTROBOX enter dev"
}

@test "failure: docker start failing is reported with the recovery, exit 1" {
    FAKE_START_RC=1 _enter --distrobox "${DISTROBOX}" --timeout 30
    assert_failure 1
    assert_output --partial "failed: docker start dev failed"
    assert_output --partial "distrobox rm -f dev"
    refute_output --partial "FAKE-DISTROBOX"
}

# --- cleanup of the background follower -------------------------------------------

@test "cleanup: after a successful first launch no log follower is left behind" {
    _long_init_script
    _enter --distrobox "${DISTROBOX}"
    assert_success
    assert [ -s "${FAKE_LOGS_PIDFILE}" ]
    run enter_fake_logs_alive
    assert_failure
}

@test "cleanup: Ctrl-C (SIGINT) mid-initialisation removes the follower, keeps the box and says so" {
    enter_fake_logs '0|distrobox: Installing basic packages...'
    local _err="${BATS_TEST_TMPDIR}/err" _pid _rc=0 _i
    # Job control on, so the background job does not start with SIGINT
    # ignored (a non-interactive shell ignores it for `&` jobs otherwise).
    set -m
    WORKTOOL_INIT_INTERVAL=1 "${ENTER}" --distrobox "${DISTROBOX}" --timeout 60 2>"${_err}" &
    _pid=$!
    set +m
    for _i in $(seq 1 50); do
        [[ -s "${FAKE_LOGS_PIDFILE}" ]] && grep -q 'elapsed' "${_err}" && break
        sleep 0.2
    done
    kill -INT "${_pid}"
    wait "${_pid}" || _rc=$?
    assert_equal "${_rc}" "130"
    run cat "${_err}"
    assert_output --partial "interrupted"
    assert_output --partial "docker logs -f dev"
    run enter_fake_logs_alive
    assert_failure
    run grep -E '^docker (stop|rm|kill)' "${FAKE_DOCKER_CALLS}"
    assert_failure
}

@test "cleanup: SIGTERM mid-initialisation removes the follower too (exit 143)" {
    enter_fake_logs '0|distrobox: Installing basic packages...'
    local _pid _rc=0 _i
    WORKTOOL_INIT_INTERVAL=1 "${ENTER}" --distrobox "${DISTROBOX}" --timeout 60 2>/dev/null &
    _pid=$!
    for _i in $(seq 1 50); do
        [[ -s "${FAKE_LOGS_PIDFILE}" ]] && break
        sleep 0.2
    done
    kill -TERM "${_pid}"
    wait "${_pid}" || _rc=$?
    assert_equal "${_rc}" "143"
    run enter_fake_logs_alive
    assert_failure
}

# --- progress rendering ------------------------------------------------------------

@test "progress on a TTY overwrites one line in place; otherwise one line per update" {
    run bash -c 'source "$1"; _progress_emit 1 "tick"; _progress_emit 1 "tock"; _progress_end' \
        _ "${ENTER}"
    assert_success
    assert_output "$(printf '\r\033[Ktick\r\033[Ktock\n')"
    run bash -c 'source "$1"; _progress_emit 0 "tick"; _progress_emit 0 "tock"; _progress_end' \
        _ "${ENTER}"
    assert_success
    assert_output "$(printf 'tick\ntock')"
}

@test "elapsed time is shown as seconds, then minutes and seconds" {
    run bash -c 'source "$1"; _fmt_duration 9; _fmt_duration 60; _fmt_duration 212' _ "${ENTER}"
    assert_success
    assert_output "$(printf '9s\n1m00s\n3m32s')"
}
