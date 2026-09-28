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
#   window and returns 0 far sooner than the command it was asked to run
#   could take - here, before that command has begun at all. Its exit
#   status therefore says nothing about the command - a test that treats
#   "ghostty exited 0" as "the command ran" is green while the window
#   lives on in a background process nobody reaps. The worktool test
#   config pins `gtk-single-instance = false` and asserts an in-box
#   marker file exactly because of this.
#
# HOW (every claim below is OBSERVED; nothing is asserted by fiat)
#   One Xvfb display and one private session bus (dbus-run-session), one
#   config with `gtk-single-instance = true`, and a window payload
#   (<WORKDIR>/window-command.sh) that names itself the moment it begins
#   and could only write to DONE if it ever RETURNED: it records its pid
#   and its starttime, then blocks in `sleep infinity`. Every step of it
#   is failure-checked, so a payload that could not leave its evidence
#   never goes on to block. The file count under STARTED is therefore the
#   number of window commands that really started, and any file under
#   DONE would mean one of them returned (none can).
#
#     1. start the primary in the background and wait (bounded) until
#        STARTED holds exactly one file, i.e. its command really began;
#     2. run ghostty a second time under its own `timeout`; IMMEDIATELY
#        AFTER it returns, take a timestamp and then read the STARTED
#        count. Neither reading is an atomic snapshot of the return
#        instant - the timestamp is taken first and a couple of
#        subshells run in between - so a forwarded command that started
#        very fast would be counted here and turn the case RED. The
#        sampling delay can only cost a pass, never buy one;
#     3. wait (bounded) for STARTED to reach two, and compare that second
#        file's mtime with the timestamp from step 2, so the ORDER
#        (timestamp first, command's own mtime after) is measured and not
#        merely assumed from the order the script happens to look in;
#     4. count this run's window commands that are still running, check
#        the primary ghostty process is still there, and count DONE.
#
#   Output on stdout, one `KEY=VALUE` per line, for the spec to assert on:
#     PRIMARY=up|died-before-ready|not-ready-in-<n>s
#     SECOND_RC=<status of the second launch>
#     SECOND_ELAPSED=<seconds it took>
#     STARTED_AT_RETURN=<window commands begun, read just after it returned>
#     FORWARDED_STARTED=yes|no        (a SECOND window command began)
#     FORWARDED_AFTER_RETURN=yes|no   (measured: its mtime > return time)
#     FORWARDED_DELAY_MS=<ms between the return and that command starting>
#     RUNNING_COMMANDS=<this run's window commands still running: pid
#                       present, same starttime, not a zombie>
#     PRIMARY_WRAPPER_ALIVE=yes|no    (the ghostty process that owns the
#                                      bus name, NOT the command's shell -
#                                      the STARTED count is what proves a
#                                      command began)
#     COMMAND_FINISHED=no|yes         (observed: DONE is empty / is not)
#
# Usage: ghostty_single_instance.sh <workdir>
#
# Two self-check modes exist for the fast test tier (no display, no bus,
# no ghostty needed), driven by test/unit/ghostty_fixture_spec.bats:
#   ghostty_single_instance.sh --check-workdir <workdir>
#   ghostty_single_instance.sh --check-epoch-ms <nanoseconds>
# Each runs one guard and exits with its verdict, creating nothing.
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

# Two more modes exist ONLY so the guards below can be tested without a
# display, a session bus or a real ghostty: they run one check and exit
# with its verdict. test/unit/ghostty_fixture_spec.bats drives them.
CHECK_WORKDIR_FLAG="--check-workdir"
CHECK_EPOCH_FLAG="--check-epoch-ms"

MODE="outer"
case "${1:-}" in
    "${SCENARIO_FLAG}")      MODE="scenario"; shift ;;
    "${CHECK_WORKDIR_FLAG}") MODE="check-workdir"; shift ;;
    "${CHECK_EPOCH_FLAG}")   MODE="check-epoch"; shift ;;
esac

# --check-epoch-ms takes a value, not a workdir: serve it before the
# workdir plumbing below runs.
if [[ "${MODE}" == "check-epoch" ]]; then
    _EPOCH_ARG="${1:-}"
    [[ -n "${_EPOCH_ARG}" ]] \
        || _die "usage: ghostty_single_instance.sh ${CHECK_EPOCH_FLAG} <nanoseconds>"
fi

WORKDIR="${1:-}"
if [[ "${MODE}" != "check-epoch" ]]; then
    [[ -n "${WORKDIR}" ]] || _die "usage: ghostty_single_instance.sh <workdir>"
fi

STARTED="${WORKDIR}/started"
DONE="${WORKDIR}/done"
CONFIG_HOME="${WORKDIR}/config"
WINDOW_CMD="${WORKDIR}/window-command.sh"

# The two check modes only inspect values; they create nothing and export
# nothing (a refused path must not leave a directory behind).
if [[ "${MODE}" == "outer" || "${MODE}" == "scenario" ]]; then
    mkdir -p "${STARTED}" "${DONE}" "${CONFIG_HOME}/ghostty" \
        || _die "cannot create the scenario directories under ${WORKDIR}"
    export XDG_CONFIG_HOME="${CONFIG_HOME}"
    export LIBGL_ALWAYS_SOFTWARE=1
    export GDK_BACKEND=x11
fi

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
#
# The `date` output is validated before it is used: a `date` without `%N`
# echoes the letter back and the arithmetic would fail in a confusing
# place, so this fails loudly with its own message instead. `10#` keeps a
# leading zero from being read as octal.
#
# EXACTLY 19 digits, and no larger than 2^63-1. Epoch nanoseconds have
# been 19 digits since 2001 and cross 2^63-1 in 2262 - so the digit count
# alone is NOT a range check: 9223372036854775808 .. 9999999999999999999
# are 19 digits and would WRAP in bash arithmetic (measured:
# 9223372036854775808 came out as -9223372036854 ms).
#
# The bound is checked on the two halves of the string, each of which
# fits comfortably in 64 bits, so the check itself can never wrap - and
# the millisecond value is taken by dropping the last SIX digits (ns ->
# ms) rather than dividing the full value, so no arithmetic ever touches
# a 19-digit number.
_EPOCH_NS_MAX_HI='9223372036'   # first 10 digits of 2^63-1
_EPOCH_NS_MAX_LO='854775807'    # last 9
_epoch_ms() {
    local _hi _lo
    [[ "$1" =~ ^[0-9]{19}$ ]] \
        || _die "date did not return 19-digit epoch nanoseconds (got '$1'): does this date support %N?"
    _hi="${1:0:10}"
    _lo="${1:10}"
    if (( 10#${_hi} > 10#${_EPOCH_NS_MAX_HI} )) \
        || { (( 10#${_hi} == 10#${_EPOCH_NS_MAX_HI} )) \
            && (( 10#${_lo} > 10#${_EPOCH_NS_MAX_LO} )); }; then
        _die "epoch nanoseconds '$1' exceed 2^63-1, which 64-bit shell arithmetic cannot hold"
    fi
    printf '%s\n' "$(( 10#${1:0:13} ))"
}
_now_ms() { _epoch_ms "$(date +%s%N)"; }
_mtime_ms() { _epoch_ms "$(date -r "$1" +%s%N)"; }

# The most recently created start file, i.e. the window command that began
# last (the forwarded one, once there are two).
_newest_started() {
    find "${STARTED}" -maxdepth 1 -type f -printf '%T@ %p\n' \
        | sort -n | tail -n 1 | cut -d' ' -f2-
}

# Print `<state> <starttime>` for pid $1 out of /proc/<pid>/stat: the
# field after the `) ` is the state (field 3) and the 20th after it is
# starttime (field 22). Splitting after the last `) ` is what keeps a
# comm containing spaces or parentheses from shifting every field.
_proc_state_start() {
    local _line _rest
    _line="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    _rest="${_line##*") "}"
    [[ "${_rest}" != "${_line}" ]] || return 1
    printf '%s %s\n' \
        "$(printf '%s\n' "${_rest}" | cut -d' ' -f1)" \
        "$(printf '%s\n' "${_rest}" | cut -d' ' -f20)"
}

# How many of THIS run's window commands are still running, asked of the
# command processes themselves. Every start file holds the pid of the
# shell running that window's command AND that process's starttime, so a
# command counts here only when the pid still exists, its starttime is
# the SAME one it recorded (a recycled pid has a later one) and it is not
# a zombie. `kill -0` alone would accept both of those.
#
# Process-name or command-line scanning would be wrong here twice over:
# inside the system-real runner the nested engine's containers share the
# runner's PID namespace (the deliberate-hang case leaves a `sleep` in the
# dev box), and `pgrep -f` matches any command line quoting the pattern,
# including the harness that launched this script. Both were measured
# returning 4 and 5 where the answer is 2.
_running_commands() {
    local _f _pid _start _now _state _now_start _n=0
    for _f in "${STARTED}"/w.*; do
        [[ -f "${_f}" ]] || continue
        read -r _pid _start <"${_f}" || continue
        [[ "${_pid}" =~ ^[0-9]+$ && "${_start}" =~ ^[0-9]+$ ]] || continue
        _now="$(_proc_state_start "${_pid}")" || continue
        _state="${_now%% *}"
        _now_start="${_now##* }"
        [[ "${_state}" != "Z" ]] || continue
        [[ "${_now_start}" == "${_start}" ]] || continue
        _n=$(( _n + 1 ))
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

# The payload every ghostty window runs. It lives in a file rather than
# inline in the config so that none of its `$`, `(` or `)` has to survive
# ghostty's own argv splitting; the config then only has to carry the
# path, which _write_config double quotes.
#
# It records its pid AND its starttime (field 22 of /proc/<pid>/stat), so
# the checker can tell this process from a later one that reused the pid.
# Every step is failure-checked: a payload that could not leave its
# evidence must not go on to block, or the scenario would have a running
# command with nothing to show for it.
_write_window_command() {
    cat >"${WINDOW_CMD}" <<EOF
#!/bin/sh
# Written by ghostty_single_instance.sh; one instance per ghostty window.
set -u
_line="\$(cat /proc/\$\$/stat)" || exit 1
_rest="\${_line##*") "}"
[ "\${_rest}" != "\${_line}" ] || exit 1
_start="\$(printf '%s\n' "\${_rest}" | cut -d' ' -f20)"
[ -n "\${_start}" ] || exit 1
printf '%s %s\n' "\$\$" "\${_start}" >"${STARTED}/w.\$\$" || exit 1
sleep infinity || exit 1
printf 'done\n' >"${DONE}/d.\$\$"
EOF
    chmod +x "${WINDOW_CMD}"
}

# `gtk-single-instance = true` is the whole point: this is the setting the
# real test config pins to false.
#
# The payload path is SINGLE QUOTED.
#
# A `command` without the `direct:` prefix is a SHELL command line in
# ghostty 1.3.0: the string is handed to `/bin/sh -c`, so it goes through
# a second round of parsing that config-level quoting has to survive.
# Measured against the ghostty in the runner image, with the payload
# writing to a fixed path so only the path handoff was under test:
#
#   form                        space    $ in path   backtick in path
#   direct:, unquoted           BROKEN   -           -
#   shell, double quoted        ok       BROKEN      BROKEN (executed)
#   shell, single quoted        ok       ok          ok
#
# `direct:` skips the shell but does no quoting at all, so it cannot
# carry a workdir with a space (the launch dies on its timeout); double
# quotes let `$` expand and a backtick RUN - a path-shaped injection.
# Single quotes carry all three, which is what this uses. The one
# character single quoting cannot carry is the single quote itself;
# _check_workdir refuses it, along with the others that would break out
# of, or terminate, the quoted run.
_write_config() {
    cat >"${CONFIG_HOME}/ghostty/config" <<EOF
gtk-single-instance = true
command = /bin/sh '${WINDOW_CMD}'
EOF
}

# Refuse a workdir whose path cannot be handed to ghostty safely.
#
# A single quote ends the quoted run and a newline ends the config line:
# either would produce a config that parses into some other command.
# `$`, a backtick, a double quote and a backslash are all carried
# literally INSIDE single quotes - they are refused anyway, as defence in
# depth: they are exactly what turns dangerous the moment the quoting
# form changes, and nothing this fixture is pointed at needs them.
# Whitespace IS supported (that is what the quoting is for).
#
# Each character gets its own message, so a refusal says which one.
_check_workdir() {
    [[ "${WINDOW_CMD}" != *"'"* ]] \
        || _die "workdir path must not contain a single quote: ${WORKDIR}"
    [[ "${WINDOW_CMD}" != *$'\n'* ]] \
        || _die "workdir path must not contain a newline: ${WORKDIR}"
    [[ "${WINDOW_CMD}" != *'$'* ]] \
        || _die "workdir path must not contain a dollar sign: ${WORKDIR}"
    [[ "${WINDOW_CMD}" != *'`'* ]] \
        || _die "workdir path must not contain a backtick: ${WORKDIR}"
    [[ "${WINDOW_CMD}" != *'"'* ]] \
        || _die "workdir path must not contain a double quote: ${WORKDIR}"
    [[ "${WINDOW_CMD}" != *\\* ]] \
        || _die "workdir path must not contain a backslash: ${WORKDIR}"
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
    # Taken as soon as possible after the return, timestamp first. These
    # are not an atomic snapshot of the return instant (see the header):
    # a forwarded command quick enough to slip into this gap would push
    # the count to 2 and fail the case, so the delay can only cost a
    # pass.
    _return_ms="$(_now_ms)"
    _at_return="$(_started_count)"
    echo "SECOND_RC=${_rc}"
    echo "SECOND_ELAPSED=$(( SECONDS - _start ))"
    # 1 means: just after this launch reported success, the command it
    # asked for had still not begun.
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

    # Both window commands are still running - pid present, starttime
    # unchanged, not a zombie ...
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

if [[ "${MODE}" == "check-workdir" ]]; then
    _check_workdir
    printf 'workdir accepted: %s\n' "${WORKDIR}"
    exit 0
fi

if [[ "${MODE}" == "check-epoch" ]]; then
    _epoch_ms "${_EPOCH_ARG}"
    exit 0
fi

if [[ "${MODE}" == "scenario" ]]; then
    _scenario
    exit $?
fi

_check_workdir
_reset_dirs || _die "cannot reset ${STARTED} / ${DONE}"
_write_window_command
_write_config
xvfb-run -a dbus-run-session -- bash "${SELF}" "${SCENARIO_FLAG}" "${WORKDIR}" \
    || _die "the single-instance scenario did not complete"
