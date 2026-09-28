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
# HOW (every claim below is OBSERVED; nothing is asserted by fiat)
#   One Xvfb display and one private session bus (dbus-run-session), one
#   config with `gtk-single-instance = true`, and a command that names
#   itself the moment it begins and could only write to DONE if it ever
#   RETURNED:
#
#     /bin/sh -c "echo $$ ><STARTED>/w.$$ && sleep infinity && echo done ><DONE>/d.$$"
#
#   The start file is named after - and holds - the pid of the shell
#   running that window's command, so the fixture can later ask those
#   exact processes whether they are still alive. `&&`, not `;`: a start
#   file that could not be written must stop the chain rather than leave
#   a blocked command with no evidence that it began. So the file count
#   under STARTED is the number of window commands that really started,
#   and any file under DONE would mean one of them returned (none can:
#   `sleep infinity` is in the way).
#
#     1. start the primary in the background and wait (bounded) until
#        STARTED holds exactly one file, i.e. its command really began;
#     2. run ghostty a second time under its own `timeout`; the instant it
#        returns, take a timestamp and read the STARTED count AGAIN -
#        still 1 means the work it just reported success for had not even
#        begun;
#     3. wait (bounded) for STARTED to reach two, and compare that second
#        file's mtime with the timestamp from step 2, so the ORDER
#        (returned first, command started after) is measured and not
#        merely assumed from the order the script happens to look in;
#     4. count this run's window commands that are still running, check
#        the primary ghostty process is still there, and count DONE.
#
#   Output on stdout, one `KEY=VALUE` per line, for the spec to assert on:
#     PRIMARY=up|died-before-ready|not-ready-in-<n>s
#     SECOND_RC=<status of the second launch>
#     SECOND_ELAPSED=<seconds it took>
#     STARTED_AT_RETURN=<window commands begun when it returned>
#     FORWARDED_STARTED=yes|no        (a SECOND window command began)
#     FORWARDED_AFTER_RETURN=yes|no   (measured: its mtime > return time)
#     FORWARDED_DELAY_MS=<ms between the return and that command starting>
#     RUNNING_COMMANDS=<this run's window commands still alive, by pid>
#     PRIMARY_WRAPPER_ALIVE=yes|no    (the ghostty process that owns the
#                                      bus name, NOT the command's shell -
#                                      the STARTED count is what proves a
#                                      command began)
#     COMMAND_FINISHED=no|yes         (observed: DONE is empty / is not)
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

# --- observation helpers -----------------------------------------------------

# How many window commands have begun / returned so far.
_started_count() { find "${STARTED}" -maxdepth 1 -type f | wc -l; }
_done_count() { find "${DONE}" -maxdepth 1 -type f | wc -l; }

# Wall clock in milliseconds, and the mtime of file $1 in the same unit,
# so the two can be compared directly.
#
# Both go through `date +%s%N` (nanoseconds) and are divided here. Ubuntu
# 26.04 ships uutils coreutils, whose `date` accepts `%3N` but IGNORES the
# width and prints all nine digits - a silent 10^6 error if the format
# string is trusted to truncate. Dividing in the shell is correct on both
# implementations.
_epoch_ms() { printf '%s\n' "$(( ${1} / 1000000 ))"; }
_now_ms() { _epoch_ms "$(date +%s%N)"; }
_mtime_ms() { _epoch_ms "$(date -r "$1" +%s%N)"; }

# The most recently created start file, i.e. the window command that began
# last (the forwarded one, once there are two).
_newest_started() {
    find "${STARTED}" -maxdepth 1 -type f -printf '%T@ %p\n' \
        | sort -n | tail -n 1 | cut -d' ' -f2-
}

# How many of THIS run's window commands are still running, asked of the
# command processes themselves: every start file is named after - and
# holds - the pid of the shell running that window's command, so this
# probes those exact pids rather than scanning for a pattern.
#
# Process-name or command-line scanning would be wrong here twice over:
# inside the system-real runner the nested engine's containers share the
# runner's PID namespace (the deliberate-hang case leaves a `sleep` in the
# dev box), and `pgrep -f` matches any command line quoting the pattern,
# including the harness that launched this script.
_running_commands() {
    local _f _pid _n=0
    for _f in "${STARTED}"/w.*; do
        [[ -f "${_f}" ]] || continue
        _pid="$(cat "${_f}")"
        [[ "${_pid}" =~ ^[0-9]+$ ]] || continue
        kill -0 "${_pid}" 2>/dev/null && _n=$(( _n + 1 ))
    done
    printf '%s\n' "${_n}"
}

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
# real test config pins to false.
_write_config() {
    cat >"${CONFIG_HOME}/ghostty/config" <<EOF
gtk-single-instance = true
command = /bin/sh -c "echo \$\$ >${STARTED}/w.\$\$ && sleep infinity && echo done >${DONE}/d.\$\$"
EOF
}

# Start from nothing, so a re-run against the same workdir cannot inherit
# another run's counts (bats hands over a fresh directory, but the
# evidence must not depend on that).
_reset_dirs() {
    rm -rf "${STARTED}" "${DONE}" || return 1
    mkdir -p "${STARTED}" "${DONE}" || return 1
}

# --- the scenario ------------------------------------------------------------

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
    local _start="${SECONDS}" _rc _return_ms _at_return
    timeout -k "${KILL_GRACE}" "${SECOND_TIMEOUT}" ghostty >/dev/null 2>&1
    _rc=$?
    # Taken BEFORE anything else, so they describe the moment of return.
    _return_ms="$(_now_ms)"
    _at_return="$(_started_count)"
    echo "SECOND_RC=${_rc}"
    echo "SECOND_ELAPSED=$(( SECONDS - _start ))"
    # 1 means: at the instant this launch reported success, the command it
    # asked for had not begun at all.
    echo "STARTED_AT_RETURN=${_at_return}"

    # Now let the forwarded window's command appear, and MEASURE when it
    # did relative to the return above.
    if _wait_started 2 "${FORWARD_START_TIMEOUT}"; then
        echo "FORWARDED_STARTED=yes"
        local _newest _started_ms
        _newest="$(_newest_started)"
        _started_ms="$(_mtime_ms "${_newest}")"
        if [[ "${_started_ms}" -gt "${_return_ms}" ]]; then
            echo "FORWARDED_AFTER_RETURN=yes"
        else
            echo "FORWARDED_AFTER_RETURN=no"
        fi
        echo "FORWARDED_DELAY_MS=$(( _started_ms - _return_ms ))"
    else
        echo "FORWARDED_STARTED=no"
        echo "FORWARDED_AFTER_RETURN=no"
        echo "FORWARDED_DELAY_MS=0"
    fi

    # Both window commands are still there, asked of their own pids ...
    echo "RUNNING_COMMANDS=$(_running_commands)"

    # ... and the ghostty process that owns the bus name outlived the
    # launch that claimed success. (This is the WRAPPER, not the command's
    # own shell; the STARTED count above is what proves a command began.)
    if kill -0 "${_primary}" 2>/dev/null; then
        echo "PRIMARY_WRAPPER_ALIVE=yes"
    else
        echo "PRIMARY_WRAPPER_ALIVE=no"
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

_reset_dirs || _die "cannot reset ${STARTED} / ${DONE}"
_write_config
xvfb-run -a dbus-run-session -- bash "${SELF}" "${SCENARIO_FLAG}" "${WORKDIR}" \
    || _die "the single-instance scenario did not complete"
