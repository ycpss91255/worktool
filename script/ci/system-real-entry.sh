#!/usr/bin/env bash
# system-real-entry.sh - entry point of the docker-in-docker runner for the
# REAL-ENGINE group of the system tier (M2).
#
# Runs INSIDE the worktool-system-real image (dockerfile/Dockerfile.system-real,
# based on docker:dind), which ci.sh --system-real-only starts with
# `docker run --rm --privileged -v <repo>:/source -w /source`. It:
#
#   1. checks it really is root with CAP_SYS_ADMIN (i.e. --privileged) and
#      that the dind image's dockerd helpers are present;
#   2. starts an isolated dockerd in the background through the image's own
#      dockerd-entrypoint.sh (which applies the dind wrapper: cgroup v2
#      nesting, tmpfs /tmp, `mount --make-rshared /`, iptables backend
#      selection, tini as pid 1 of the daemon), logging to DOCKERD_LOG;
#   3. waits until `docker info` succeeds (bounded; fails loudly with the
#      daemon log on timeout or early death);
#   4. runs the real-engine bats gate through ci.sh --ci-system-real, so the
#      tier rules (specs must exist, at least one case, no failure, no skip)
#      apply to this group exactly like every other tier;
#   5. on exit, best-effort cleanup: `distrobox rm -f dev`, remove any
#      leftover container, stop dockerd. Everything lives in this container
#      (the nested daemon's /var/lib/docker is an anonymous volume of the
#      dind image) and dies with it under --rm, so the host daemon never
#      sees the box.
#
# Environment (all optional):
#   WORKTOOL_DOCKERD_LOG            path of the nested daemon log
#                                   (default /var/log/worktool-dockerd.log;
#                                   NOT under /tmp, which the dind wrapper
#                                   re-mounts as tmpfs at daemon start)
#   WORKTOOL_DOCKERD_READY_TIMEOUT  seconds to wait for `docker info`
#                                   (default 90)
#
# Exit-code-contract script: default guards are `set -uo pipefail` (no `-e`);
# failures are surfaced explicitly via _die so a nonzero exit is always
# intentional. Exit status is the gate's status.

set -uo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CI_SH="${SCRIPT_DIR}/ci.sh"

DOCKERD_LOG="${WORKTOOL_DOCKERD_LOG:-/var/log/worktool-dockerd.log}"
DOCKERD_READY_TIMEOUT="${WORKTOOL_DOCKERD_READY_TIMEOUT:-90}"
DOCKERD_STOP_TIMEOUT=20
DOCKERD_SOCKET="unix:///var/run/docker.sock"
BOX_NAME="dev"

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
        tail -n 60 "${DOCKERD_LOG}" >&2 || true
        _info "--- end of dockerd log"
    fi
}

# --- Preflight ---------------------------------------------------------------

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
    [[ -x "${CI_SH}" ]] || _die "ci.sh not found at ${CI_SH} (is the repo mounted at /source?)"
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

_wait_dockerd() {
    local _start="${SECONDS}"
    local _deadline=$(( _start + DOCKERD_READY_TIMEOUT ))
    while (( SECONDS < _deadline )); do
        if ! kill -0 "${DOCKERD_PID}" 2>/dev/null; then
            _tail_dockerd_log
            _die "dockerd exited before becoming ready"
        fi
        if docker info >/dev/null 2>&1; then
            _info "dockerd ready after $(( SECONDS - _start ))s"
            docker info --format \
                '[system-real] engine {{.ServerVersion}} driver={{.Driver}} cgroup={{.CgroupDriver}}/{{.CgroupVersion}}' >&2 \
                || true
            return 0
        fi
        sleep 1
    done
    _tail_dockerd_log
    _die "dockerd not ready after ${DOCKERD_READY_TIMEOUT}s"
}

_stop_dockerd() {
    [[ -n "${DOCKERD_PID}" ]] || return 0
    kill -0 "${DOCKERD_PID}" 2>/dev/null || return 0
    _info "stopping nested dockerd (pid ${DOCKERD_PID})"
    kill -TERM "${DOCKERD_PID}" 2>/dev/null || true
    local _deadline=$(( SECONDS + DOCKERD_STOP_TIMEOUT ))
    while kill -0 "${DOCKERD_PID}" 2>/dev/null && (( SECONDS < _deadline )); do
        sleep 1
    done
    if kill -0 "${DOCKERD_PID}" 2>/dev/null; then
        _info "dockerd did not stop in ${DOCKERD_STOP_TIMEOUT}s - killing (the container dies anyway)"
        kill -KILL "${DOCKERD_PID}" 2>/dev/null || true
    fi
}

# Best-effort teardown; never fails the run (the gate's own exit code is
# already decided) and never blocks for long.
_cleanup() {
    local _rc=$?
    trap - EXIT
    if [[ -n "${DOCKERD_PID}" ]] && docker info >/dev/null 2>&1; then
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${BOX_NAME}"; then
            _info "cleanup: box '${BOX_NAME}' still present - removing"
            DBX_CONTAINER_MANAGER=docker timeout 60 distrobox rm -f "${BOX_NAME}" \
                >/dev/null 2>&1 </dev/null || true
            docker rm -f "${BOX_NAME}" >/dev/null 2>&1 || true
        fi
        _info "cleanup: containers left in the nested daemon: $(docker ps -aq 2>/dev/null | wc -l)"
    fi
    _stop_dockerd
    if [[ "${_rc}" -ne 0 ]]; then
        _tail_dockerd_log
    fi
    exit "${_rc}"
}

# --- Main --------------------------------------------------------------------
main() {
    _preflight
    trap _cleanup EXIT
    _start_dockerd
    _wait_dockerd
    _info "running the real-engine system gate"
    "${CI_SH}" --ci-system-real
}

# Guard: only run main when executed directly, not when sourced.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    main "$@"
fi
