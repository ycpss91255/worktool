#!/usr/bin/env bash
# system-real-entry.sh - entry point of the docker-in-docker runner for the
# REAL-ENGINE group of the system tier (M2).
#
# Runs INSIDE the worktool-system-real image (dockerfile/Dockerfile.system-real:
# ubuntu:26.04 carrying the engine binaries and dind helpers copied from the
# pinned docker:dind image), which test.sh --system-real starts with
# `docker run --rm --privileged -v <repo>:/source -w /source`. It:
#
#   1. validates the overridable timeouts (positive integers only), then
#      checks it really is root with CAP_SYS_ADMIN (i.e. --privileged) and
#      that the dind image's dockerd helpers are present;
#   2. starts an isolated dockerd in the background through the image's own
#      dockerd-entrypoint.sh (which applies the dind wrapper: cgroup v2
#      nesting, tmpfs /tmp, `mount --make-rshared /`, iptables backend
#      selection, tini as pid 1 of the daemon), logging to DOCKERD_LOG;
#   3. waits until `docker info` succeeds (bounded; fails loudly with the
#      daemon log on timeout or early death);
#   4. runs the real-engine bats gate through test.sh --ci-system-real, so the
#      tier rules (required spec present and non-empty, at least one case,
#      no failure, no skip) apply to this group exactly like every other
#      tier;
#   5. on exit, best-effort cleanup: `distrobox rm -f dev`, remove any
#      leftover container, report how many containers the nested daemon
#      still holds (honestly "unknown" if it cannot be asked), stop
#      dockerd. Everything lives in this container (the nested daemon's
#      /var/lib/docker is an anonymous volume of the dind image) and dies
#      with it under --rm, so the host daemon never sees the box.
#
# Every engine call this entry makes (`docker info` probes and details,
# `docker ps`, `distrobox rm`, `docker rm`) runs under its own `timeout`
# (_bounded), so a daemon that wedges can never hold a local run past the
# deadlines below: the wait loop's total (WORKTOOL_DOCKERD_READY_TIMEOUT)
# is authoritative on BOTH its paths (not ready -> fail; ready -> the
# engine-details query after the probe only gets what is left of that
# budget) and the cleanup trap is capped at a known worst case. The two
# overridable timeouts are validated before anything starts, since
# `timeout 0` means "no bound". CI's job timeout is the last resort, not
# the first.
#
# Environment (all optional; the two timeouts must be positive integers,
# anything else - 0, negative, non-numeric - fails the entry before dockerd
# is started):
#   WORKTOOL_DOCKERD_LOG            path of the nested daemon log
#                                   (default /var/log/worktool-dockerd.log;
#                                   NOT under /tmp, which the dind wrapper
#                                   re-mounts as tmpfs at daemon start)
#   WORKTOOL_DOCKERD_READY_TIMEOUT  seconds to wait for `docker info`
#                                   (default 90; authoritative total)
#   WORKTOOL_DOCKER_CALL_TIMEOUT    seconds per short engine query
#                                   (`docker info` / `docker ps`; default 10)
#
# Guards: `set -euo pipefail` (doc/adr/0001-scripts-use-errexit.md): an
# unhandled failure stops the script at once. A non-zero status the script
# EXPECTS is handled explicitly (`if ! cmd`, `cmd || _rc=$?`), never
# swallowed with `|| true`, so every exit code documented here stays the
# script's own. Exit status is the gate's status.

set -euo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_SH="${SCRIPT_DIR}/test.sh"

DOCKERD_LOG="${WORKTOOL_DOCKERD_LOG:-/var/log/worktool-dockerd.log}"
DOCKERD_READY_TIMEOUT="${WORKTOOL_DOCKERD_READY_TIMEOUT:-90}"
DOCKERD_STOP_TIMEOUT=20
DOCKERD_SOCKET="unix:///var/run/docker.sock"
BOX_NAME="dev"

# Per-call bounds (seconds). Short queries (`docker info` / `docker ps`) get
# DOCKER_CALL_TIMEOUT; the two removals in the cleanup trap get their own,
# larger budgets. KILL_GRACE is how long after SIGTERM `timeout` escalates
# to SIGKILL, so the bound is hard even for a CLI stuck in a socket read.
DOCKER_CALL_TIMEOUT="${WORKTOOL_DOCKER_CALL_TIMEOUT:-10}"
DISTROBOX_RM_TIMEOUT=60
DOCKER_RM_TIMEOUT=30
KILL_GRACE=5

# Exported so the spec can print the daemon log on failure.
export WORKTOOL_DOCKERD_LOG="${DOCKERD_LOG}"

DOCKERD_PID=""

# --- Logging -----------------------------------------------------------------
_info() { printf '[system-real] %s\n' "$*" >&2; }

_die() {
    printf '[system-real] ERROR: %s\n' "$*" >&2
    exit 1
}

_tail_dockerd_log() {
    if [[ -f "${DOCKERD_LOG}" ]]; then
        _info "--- dockerd log (tail): ${DOCKERD_LOG}"
        tail -n 60 "${DOCKERD_LOG}" >&2 \
            || _info "(the dockerd log could not be read)"
        _info "--- end of dockerd log"
    fi
}

# Run "$@" under a hard bound of $1 seconds: SIGTERM at the deadline,
# SIGKILL KILL_GRACE seconds later if it is still there. Exit status is the
# command's (124 on timeout), so callers keep their `|| ...` handling.
_bounded() {
    local _secs="$1"
    shift
    timeout -k "${KILL_GRACE}" "${_secs}" "$@"
}

# --- Preflight ---------------------------------------------------------------

# $1 = environment variable name (for the message), $2 = its effective
# value: must be a positive integer number of seconds. `timeout 0` means "no
# bound" and a non-number reads as 0 in bash arithmetic, so either would
# quietly void every deadline above; refuse them instead.
_check_positive_seconds() {
    [[ "$2" =~ ^[1-9][0-9]*$ ]] \
        || _die "$1 must be a positive integer (seconds), got '$2'"
}

# Validate the overridable timeouts. Runs FIRST in main, before preflight and
# long before dockerd is started, so a bad value fails fast and cleanly.
_check_timeouts() {
    _check_positive_seconds WORKTOOL_DOCKERD_READY_TIMEOUT "${DOCKERD_READY_TIMEOUT}"
    _check_positive_seconds WORKTOOL_DOCKER_CALL_TIMEOUT "${DOCKER_CALL_TIMEOUT}"
}

# CAP_SYS_ADMIN is bit 21 of the effective capability mask; a nested dockerd
# cannot mount / manage cgroups without it. Its absence means the runner was
# started without --privileged, which is the one thing this entry needs.
_has_cap_sys_admin() {
    local _cap_hex _cap
    _cap_hex="$(awk '/^CapEff:/ { print $2 }' /proc/self/status)"
    [[ -n "${_cap_hex}" ]] || return 1
    printf -v _cap '%d' "0x${_cap_hex}" 2>/dev/null || return 1
    (( (_cap >> 21) & 1 ))
}

_preflight() {
    [[ "$(id -u)" -eq 0 ]] \
        || _die "must run as root inside the runner (uid $(id -u))"
    _has_cap_sys_admin \
        || _die "CAP_SYS_ADMIN missing - start the runner with 'docker run --privileged'"
    [[ -x /usr/local/bin/dockerd-entrypoint.sh ]] \
        || _die "dockerd-entrypoint.sh missing - not the docker:dind based runner image"
    command -v dockerd >/dev/null 2>&1 || _die "dockerd not found in the runner image"
    command -v docker >/dev/null 2>&1 || _die "docker CLI not found in the runner image"
    command -v distrobox >/dev/null 2>&1 || _die "distrobox not found in the runner image"
    [[ -x "${TEST_SH}" ]] || _die "test.sh not found at ${TEST_SH} (is the repo mounted at /source?)"
}

# --- Nested daemon lifecycle -------------------------------------------------

_start_dockerd() {
    mkdir -p "$(dirname -- "${DOCKERD_LOG}")" || _die "cannot create log dir for ${DOCKERD_LOG}"
    : >"${DOCKERD_LOG}" || _die "cannot write ${DOCKERD_LOG}"
    _info "starting nested dockerd (log: ${DOCKERD_LOG})"
    # Passing `dockerd ...` explicitly (rather than no args) makes the image
    # entrypoint skip its TLS/tcp defaults and only apply the dind wrapper.
    /usr/local/bin/dockerd-entrypoint.sh dockerd --host="${DOCKERD_SOCKET}" \
        >"${DOCKERD_LOG}" 2>&1 &
    DOCKERD_PID=$!
}

# Log the engine's version / driver / cgroup line after a successful
# readiness probe. $1 = the readiness deadline (in SECONDS terms): the query
# only gets what is LEFT of the readiness budget (min(DOCKER_CALL_TIMEOUT,
# remaining)), and is skipped outright when that budget is already spent -
# so it can never stretch the wait past the deadline the probe was held to.
# Diagnostics only: readiness was decided by the probe, this never fails.
_engine_details() {
    local _deadline="$1"
    local _left=$(( _deadline - SECONDS ))
    if (( _left < 1 )); then
        _info "engine details skipped (readiness budget spent)"
        return 0
    fi
    (( _left > DOCKER_CALL_TIMEOUT )) && _left="${DOCKER_CALL_TIMEOUT}"
    _bounded "${_left}" docker info --format \
        '[system-real] engine {{.ServerVersion}} driver={{.Driver}} cgroup={{.CgroupDriver}}/{{.CgroupVersion}}' >&2 \
        || _info "engine details unavailable (query failed or exceeded its ${_left}s bound within the readiness budget)"
    return 0
}

# Wait for the nested daemon to answer `docker info`. DOCKERD_READY_TIMEOUT
# is the authoritative total on both paths: each probe is bounded by the
# shorter of DOCKER_CALL_TIMEOUT and the time left, so a probe that hangs
# on a wedged socket cannot push the loop past its deadline, and after a
# successful probe the deadline is re-checked so the engine-details query
# gets only what remains (_engine_details). A failed probe re-checks the
# deadline before sleeping, so the last (killed) probe is never followed by
# another sleep. Worst case for the whole function, ready or not:
# deadline + KILL_GRACE + 1s (the +1s is the integer granularity of SECONDS).
_wait_dockerd() {
    local _start="${SECONDS}"
    local _deadline=$(( _start + DOCKERD_READY_TIMEOUT ))
    local _left
    while (( SECONDS < _deadline )); do
        if ! kill -0 "${DOCKERD_PID}" 2>/dev/null; then
            _tail_dockerd_log
            _die "dockerd exited before becoming ready"
        fi
        _left=$(( _deadline - SECONDS ))
        (( _left > DOCKER_CALL_TIMEOUT )) && _left="${DOCKER_CALL_TIMEOUT}"
        # `timeout 0` would mean "no bound" - never let the clock tick to it.
        (( _left < 1 )) && _left=1
        # A probe that succeeds did so within its bound, i.e. within the
        # readiness budget: that alone decides readiness.
        if _bounded "${_left}" docker info >/dev/null 2>&1; then
            _info "dockerd ready after $(( SECONDS - _start ))s"
            _engine_details "${_deadline}"
            return 0
        fi
        # A probe that failed (or was killed) at the deadline must not buy
        # the loop one more second of sleep: that second is what would push
        # the failure path past deadline + KILL_GRACE + 1s.
        (( SECONDS < _deadline )) || break
        sleep 1
    done
    _tail_dockerd_log
    _die "dockerd not ready after ${DOCKERD_READY_TIMEOUT}s"
}

_stop_dockerd() {
    [[ -n "${DOCKERD_PID}" ]] || return 0
    kill -0 "${DOCKERD_PID}" 2>/dev/null || return 0
    _info "stopping nested dockerd (pid ${DOCKERD_PID})"
    # Refused only when the daemon exited since the probe above: nothing
    # left to stop, and the wait below sees it gone.
    kill -TERM "${DOCKERD_PID}" 2>/dev/null \
        || _info "dockerd (pid ${DOCKERD_PID}) exited before SIGTERM"
    local _deadline=$(( SECONDS + DOCKERD_STOP_TIMEOUT ))
    while kill -0 "${DOCKERD_PID}" 2>/dev/null && (( SECONDS < _deadline )); do
        sleep 1
    done
    if kill -0 "${DOCKERD_PID}" 2>/dev/null; then
        _info "dockerd did not stop in ${DOCKERD_STOP_TIMEOUT}s - killing (the container dies anyway)"
        kill -KILL "${DOCKERD_PID}" 2>/dev/null \
            || _info "dockerd (pid ${DOCKERD_PID}) exited before SIGKILL"
    fi
}

# Print how many containers the nested daemon still holds - or
# "unknown (query failed)" when the bounded `docker ps` fails or times out,
# never a fake 0 (a wedged daemon must not read as a clean one).
_leftover_count() {
    local _ids
    _ids="$(_bounded "${DOCKER_CALL_TIMEOUT}" docker ps -aq 2>/dev/null)" || {
        printf 'unknown (query failed)\n'
        return 0
    }
    if [[ -z "${_ids}" ]]; then
        printf '0\n'
    else
        printf '%s\n' "${_ids}" | wc -l
    fi
}

# Best-effort teardown; never fails the run (the gate's own exit code is
# already decided) and never blocks for long: every engine call is bounded,
# so even against a wedged daemon the trap is capped at about
# 3 x DOCKER_CALL_TIMEOUT + DISTROBOX_RM_TIMEOUT + DOCKER_RM_TIMEOUT +
# DOCKERD_STOP_TIMEOUT (+ KILL_GRACE per escalation) seconds.
_cleanup() {
    local _rc=$?
    trap - EXIT
    if [[ -n "${DOCKERD_PID}" ]] \
        && _bounded "${DOCKER_CALL_TIMEOUT}" docker info >/dev/null 2>&1; then
        if _bounded "${DOCKER_CALL_TIMEOUT}" docker ps -a --format '{{.Names}}' 2>/dev/null \
            | grep -x "${BOX_NAME}" >/dev/null; then
            _info "cleanup: box '${BOX_NAME}' still present - removing"
            _bounded "${DISTROBOX_RM_TIMEOUT}" \
                env DBX_CONTAINER_MANAGER=docker distrobox rm -f "${BOX_NAME}" \
                >/dev/null 2>&1 </dev/null \
                || _info "cleanup: distrobox rm -f ${BOX_NAME} failed or timed out (best effort; docker rm follows)"
            _bounded "${DOCKER_RM_TIMEOUT}" docker rm -f "${BOX_NAME}" >/dev/null 2>&1 \
                || _info "cleanup: docker rm -f ${BOX_NAME} failed or timed out (best effort)"
        fi
        _info "cleanup: containers left in the nested daemon: $(_leftover_count)"
    fi
    _stop_dockerd
    if [[ "${_rc}" -ne 0 ]]; then
        _tail_dockerd_log
    fi
    exit "${_rc}"
}

# --- Main --------------------------------------------------------------------
main() {
    _check_timeouts
    _preflight
    trap _cleanup EXIT
    _start_dockerd
    _wait_dockerd
    _info "running the real-engine system gate"
    "${TEST_SH}" --ci-system-real
}

# Guard: only run main when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    main "$@"
fi
