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
# HOW (every claim below is OBSERVED, nothing is asserted by fiat)
#   One Xvfb display and one private session bus (dbus-run-session), one
#   config with `gtk-single-instance = true`, and a command that leaves a
#   UNIQUE start file per window and can only ever finish after a
#   `sleep infinity`:
#
#     /bin/sh -c "mktemp <STARTED>/w.XXXXXX; sleep infinity; mktemp <DONE>/d.XXXXXX"
#
#   so the number of files under STARTED is the number of window commands
#   that really began, and any file under DONE would mean one of them
#   returned (it cannot).
#
#     1. start the primary in the background and wait (bounded) until
#        STARTED holds exactly one file, i.e. its command really began;
#     2. run ghostty a second time under its own `timeout`, recording its
#        status and how long it took;
#     3. wait (bounded) for STARTED to reach two files - that second file
#        is the forwarded window's command starting, which is what makes
#        this a forwarding and not just "a second process exited fast";
#     4. check the primary is still alive (`kill -0`) and count DONE.
#
#   Output on stdout, one `KEY=VALUE` per line, for the spec to assert on:
#     PRIMARY=up|died-before-ready|not-ready-in-<n>s
#     SECOND_RC=<status of the second launch>
#     SECOND_ELAPSED=<seconds it took>
#     FORWARDED_STARTED=yes|no   (a SECOND window command began)
#     PRIMARY_ALIVE=yes|no       (the primary outlived the second launch)
#     COMMAND_FINISHED=no|yes    (observed: DONE is empty / is not)
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
PRIMARY_READY_TIMEOUT=60    # until the primary's command has started
FORWARD_START_TIMEOUT=30    # until the forwarded window's command starts
SECOND_TIMEOUT=25           # the forwarded launch's own bound
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
STARTED="${WORKDIR}/started"
DONE="${WORKDIR}/done"
CONFIG_HOME="${WORKDIR}/config"
mkdir -p "${STARTED}" "${DONE}" "${CONFIG_HOME}/ghostty" \
    || _die "cannot create the scenario directories under ${WORKDIR}"

export XDG_CONFIG_HOME="${CONFIG_HOME}"
export LIBGL_ALWAYS_SOFTWARE=1
export GDK_BACKEND=x11

# How many window commands have begun / returned so far.
_started_count() { find "${STARTED}" -maxdepth 1 -type f | wc -l; }
_done_count() { find "${DONE}" -maxdepth 1 -type f | wc -l; }

# Wait (bounded by $2 seconds) until at least $1 window commands have
# begun. Returns 1 when the deadline passes first.
_wait_started() {
    local _want="$1" _budget="$2"
    local _deadline=$(( SECONDS + _budget ))
    while (( "$(_started_count)" < _want )); do
        (( SECONDS < _deadline )) || return 1
        sleep 1
    done
    return 0
}

# `gtk-single-instance = true` is the whole point: this is the setting the
# real test config pins to false. Each window's command leaves a unique
# file the moment it begins, then blocks forever; only a command that
# RETURNED could leave a file under DONE.
_write_config() {
    cat >"${CONFIG_HOME}/ghostty/config" <<EOF
gtk-single-instance = true
command = /bin/sh -c "mktemp ${STARTED}/w.XXXXXX >/dev/null; sleep infinity; mktemp ${DONE}/d.XXXXXX >/dev/null"
EOF
}

_scenario() {
    ghostty >/dev/null 2>&1 &
    local _primary=$!
    if ! _wait_started 1 "${PRIMARY_READY_TIMEOUT}"; then
        if kill -0 "${_primary}" 2>/dev/null; then
            echo "PRIMARY=not-ready-in-${PRIMARY_READY_TIMEOUT}s"
            kill -KILL "${_primary}" 2>/dev/null
        else
            echo "PRIMARY=died-before-ready"
        fi
        return 1
    fi
    echo "PRIMARY=up"

    # From here on, a `ghostty` call can only be a forwarded one: the
    # primary owns the bus name.
    local _start="${SECONDS}" _rc
    timeout -k "${KILL_GRACE}" "${SECOND_TIMEOUT}" ghostty >/dev/null 2>&1
    _rc=$?
    echo "SECOND_RC=${_rc}"
    echo "SECOND_ELAPSED=$(( SECONDS - _start ))"

    # The second launch has already returned. Did a SECOND window command
    # begin? That is the forwarding: the work it reported success for is
    # being done by someone else, after it exited.
    if _wait_started 2 "${FORWARD_START_TIMEOUT}"; then
        echo "FORWARDED_STARTED=yes"
    else
        echo "FORWARDED_STARTED=no"
    fi

    # ... and it is the primary that is doing it.
    if kill -0 "${_primary}" 2>/dev/null; then
        echo "PRIMARY_ALIVE=yes"
    else
        echo "PRIMARY_ALIVE=no"
    fi

    # OBSERVED, not assumed: no window command has returned. The second
    # launch's exit status was therefore decided without waiting for the
    # command it asked for.
    if [[ "$(_done_count)" -eq 0 ]]; then
        echo "COMMAND_FINISHED=no"
    else
        echo "COMMAND_FINISHED=yes"
    fi

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
