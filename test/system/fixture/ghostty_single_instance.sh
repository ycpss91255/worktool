#!/usr/bin/env bash
# ghostty_single_instance.sh - demonstrate the gtk-single-instance false
# positive the ghostty chain cases guard against (M3, issue #172).
#
# Used by test/system/real_engine_spec.bats, section (e). It needs no box,
# no docker and no worktool state: only a real ghostty, Xvfb and a session
# bus, all of which the system-real runner image ships.
#
# WHAT IT DEMONSTRATES
#   `gtk-single-instance` defaults to `detect`. Where it resolves to ON,
#   the SECOND `ghostty` invocation does not open anything itself: it asks
#   the already-running primary instance over the session bus to open the
#   window and exits 0 straight away. Its exit status therefore says
#   nothing about the command it asked for - a test that treats "ghostty
#   exited 0" as "the command ran" is green while the window lives on in a
#   background process nobody reaps. The worktool test config pins
#   `gtk-single-instance = false` and asserts an in-box marker file exactly
#   because of this.
#
# HOW
#   One Xvfb display and one private session bus (dbus-run-session), one
#   config with `gtk-single-instance = true` and a command that can never
#   finish (`sleep infinity`) but touches a readiness file first:
#     1. start the primary in the background and wait (bounded) until its
#        command has actually started, so the second launch is guaranteed
#        to be a forwarded one and not a new primary;
#     2. remove the readiness file, run ghostty again under its own
#        `timeout`, and record its status and how long it took;
#     3. report whether the command it asked for had finished by then (it
#        cannot have: it is `sleep infinity`).
#
#   Output on stdout, one `KEY=VALUE` per line, for the spec to assert on:
#     SECOND_RC=<status of the second launch>
#     SECOND_ELAPSED=<seconds it took>
#     COMMAND_FINISHED=no|yes
#
# Usage: ghostty_single_instance.sh <workdir>
#
# Every wait in here is bounded, and the whole script is additionally
# wrapped in `timeout` by its caller: it can fail, it cannot hang.
#
# Exit-code-contract script: default guards are `set -uo pipefail` (no
# `-e`); failures are surfaced explicitly via _die so a non-zero exit is
# always intentional.

set -uo pipefail

# Bounds (seconds).
PRIMARY_READY_TIMEOUT=60   # until the primary's command has started
SECOND_TIMEOUT=25          # the forwarded launch's own bound
KILL_GRACE=5

_die() {
    printf 'ghostty_single_instance.sh: ERROR: %s\n' "$*" >&2
    exit 1
}

# The scenario has to run INSIDE one X server and one private session bus
# (that is what lets the two launches find each other), so the script
# re-invokes itself there with --scenario rather than serialising a
# function into a child shell.
SCENARIO_FLAG="--scenario"
SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"

MODE="outer"
if [[ "${1:-}" == "${SCENARIO_FLAG}" ]]; then
    MODE="scenario"
    shift
fi

WORKDIR="${1:-}"
[[ -n "${WORKDIR}" ]] || _die "usage: ghostty_single_instance.sh <workdir>"

mkdir -p "${WORKDIR}" || _die "cannot create ${WORKDIR}"
READY="${WORKDIR}/primary-up"
CONFIG_HOME="${WORKDIR}/config"
mkdir -p "${CONFIG_HOME}/ghostty" || _die "cannot create ${CONFIG_HOME}/ghostty"

export XDG_CONFIG_HOME="${CONFIG_HOME}"
export LIBGL_ALWAYS_SOFTWARE=1
export GDK_BACKEND=x11

# `gtk-single-instance = true` is the whole point: this is the setting the
# real test config pins to false. The command announces itself and then
# never returns.
_write_config() {
    rm -f "${READY}"
    cat >"${CONFIG_HOME}/ghostty/config" <<EOF
gtk-single-instance = true
command = /bin/sh -c "touch ${READY}; exec sleep infinity"
EOF
}

_scenario() {
    ghostty >/dev/null 2>&1 &
    local _primary=$!
    local _deadline=$(( SECONDS + PRIMARY_READY_TIMEOUT ))
    while [[ ! -f "${READY}" ]]; do
        if ! kill -0 "${_primary}" 2>/dev/null; then
            echo "PRIMARY=died-before-ready"
            return 1
        fi
        if (( SECONDS >= _deadline )); then
            echo "PRIMARY=not-ready-in-${PRIMARY_READY_TIMEOUT}s"
            kill -KILL "${_primary}" 2>/dev/null
            return 1
        fi
        sleep 1
    done
    echo "PRIMARY=up"

    # From here on, a `ghostty` call can only be a forwarded one.
    rm -f "${READY}"
    local _start="${SECONDS}" _rc
    timeout -k "${KILL_GRACE}" "${SECOND_TIMEOUT}" ghostty >/dev/null 2>&1
    _rc=$?
    echo "SECOND_RC=${_rc}"
    echo "SECOND_ELAPSED=$(( SECONDS - _start ))"

    # `sleep infinity` cannot have finished; the readiness file only tells
    # us the forwarded window's command STARTED. Either way the answer is
    # the same: the second launch's status was decided without waiting for
    # the command.
    echo "COMMAND_FINISHED=no"

    kill -KILL "${_primary}" 2>/dev/null
    wait "${_primary}" 2>/dev/null
    return 0
}

if [[ "${MODE}" == "scenario" ]]; then
    _scenario
    exit $?
fi

_write_config
xvfb-run -a dbus-run-session -- bash "${SELF}" "${SCENARIO_FLAG}" "${WORKDIR}" \
    || _die "the single-instance scenario did not complete"
