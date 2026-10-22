#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Test-only scheduler: freeze the first snapshot before its rename, then
# require either real lock contention or a second snapshot before release.
# The caller bounds this process group with timeout (including every wait).
set -euo pipefail

_repo="$1"
_sync="$2"
# shellcheck source=../../../lib/log.sh
source "${_repo}/lib/log.sh"
# shellcheck source=../../../lib/config.sh
source "${_repo}/lib/config.sh"

_await() {
    local _deadline=$((SECONDS + 5))
    until [[ -e "$1" ]]; do
        if (( SECONDS >= _deadline )); then
            printf 'barrier deadline exceeded: %s\n' "$1" >&2
            return 1
        fi
        sleep 0.01
    done
}

# Keep the actual renderer (including mutations) and freeze its output.
eval "$(declare -f _config_render | sed '1s/^_config_render /_race_render /')"
_config_render() {
    _race_render "$@" >"${_sync}/${_writer}.snapshot" || return 1
    if [[ "${_writer}" == first ]]; then
        : >"${_sync}/first-ready"
        _await "${_sync}/release-first" || return 1
    else
        printf 'snapshot\n' >"${_sync}/second-event"
    fi
    cat "${_sync}/${_writer}.snapshot"
}

# Signal only after the kernel confirms contention, before blocking on the
# same lock. Without config_set's lock this seam is never called; the
# second renderer instead signals that it has captured the stale bytes.
flock() {
    if [[ "${_writer}" == second ]]; then
        local _rc=0
        command flock -n "$@" || _rc=$?
        if (( _rc == 0 )); then return 0; fi
        if (( _rc != 1 )); then return "${_rc}"; fi
        printf 'contended\n' >"${_sync}/second-event"
    fi
    command flock "$@"
}

_cleanup() {
    local _pid
    for _pid in "${_first:-}" "${_second:-}"; do
        [[ -n "${_pid}" ]] || continue
        if kill -0 "${_pid}" 2>/dev/null; then
            kill "${_pid}" 2>/dev/null || printf 'writer already exited: %s\n' "${_pid}" >&2
        fi
        wait "${_pid}" || printf 'writer failed during cleanup: %s\n' "${_pid}" >&2
    done
}

_race() {
    trap _cleanup EXIT
    (_writer=first; config_set home first) &
    _first=$!
    _await "${_sync}/first-ready"
    (_writer=second; config_set box second) &
    _second=$!
    _await "${_sync}/second-event"
    if [[ "$(cat "${_sync}/second-event")" == snapshot ]]; then
        # The second rename must finish before the stale first rename.
        wait "${_second}"
    fi
    : >"${_sync}/release-first"
    wait "${_first}"
    wait "${_second}"
}

_race
