#!/usr/bin/env bash
# enter.sh - enter the worktool dev box, with observable first-launch
# progress (M3, issue #180).
#
# `distrobox enter <box>` on a box that was never started runs
# distrobox-init inside it (basic packages + additional_packages; ~3.5 min
# on a real machine), and all the terminal shows meanwhile is two static
# lines - no progress, no elapsed time, no log, and upstream's wait has no
# timeout. This wrapper is what the managed terminal command runs (see
# setup.sh), so a first launch is never silent:
#
#   1. First initialisation is detected with `docker inspect` State.StartedAt
#      at its zero value (0001-01-01...): a container that was never
#      started. (`docker exec ... /.containersetupdone` cannot tell - exec
#      fails on a container that is not running.) Anything else - a started
#      box, no such box, no docker - goes straight to step 4, so an
#      everyday enter costs one `docker inspect`.
#   2. First launch: stderr says the first start installs packages and can
#      take several minutes, gives `docker logs -f <box>` and the host log
#      ${XDG_CACHE_HOME:-~/.cache}/worktool/<box>-init.log. The box is
#      started with `docker start`, `docker logs -f` is followed into that
#      log in the background, and every interval (10 s) one progress line
#      shows the stage (the last `distrobox: ...` line), the elapsed time
#      and the latest init output line - overwritten in place when stderr
#      is a TTY, one line per update otherwise.
#   3. `container_setup_done` in the log is success. An `Error:` line, a
#      container that stops, a failing `docker start`, a log follower that
#      exits early (engine error, permission, lost connection) or the timeout
#      (15 min by default) is a failure: the reason, the log path, the last 20 log
#      lines and the recovery (`distrobox rm -f <box>`, then a new terminal)
#      are printed and the script exits 1. The box is NEVER stopped or
#      removed here - deleting it is the user's decision.
#   4. Hand over: `exec <distrobox> enter <box> [-- <cmd>...]`.
#
# The log follower is the only background process; a trap removes it on
# success, failure, timeout, Ctrl-C (exit 130) and SIGTERM (exit 143).
#
# The backing script of `just box enter` (script/box/justfile.box forwards
# the arguments here verbatim); the managed terminal command calls it by
# its absolute path, with an absolute --distrobox (issue #175):
#
#   ./script/box/enter.sh                          # enter the default box
#   ./script/box/enter.sh --box work -- fish       # enter work, run fish
#   ./script/box/enter.sh --timeout 1800           # allow 30 min for a first launch
#   ./script/box/enter.sh --help                   # usage
#
# This script owns its option validation: an unknown option or an invalid
# value is refused with `enter.sh: ... (see --help)` on stderr, exit 2,
# before anything runs; the whole command line is parsed before --help is
# served. All diagnostics go to STDERR via lib/log.sh.
#
# Guards: `set -euo pipefail` (doc/adr/0001-scripts-use-errexit.md). A
# non-zero status the script EXPECTS is handled explicitly (`if ! cmd`,
# `cmd || _rc=$?`), never swallowed with `|| true`.

# shellcheck source-path=SCRIPTDIR/../../lib
set -euo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
LIB_DIR="${REPO_ROOT}/lib"

# shellcheck source=log.sh
source "${LIB_DIR}/log.sh"
# shellcheck source=enter.sh
source "${LIB_DIR}/enter.sh"

# --- Defaults ----------------------------------------------------------------
ENTER_DEFAULT_TIMEOUT=900   # 15 min: ~4x the ~3.5 min a real first launch took
ENTER_DEFAULT_INTERVAL=10   # seconds between two progress lines
ENTER_TAIL_LINES=20         # log lines shown on failure
ENTER_LATEST_MAX=60         # characters of the latest output line shown
ENTER_ZERO_STARTED='0001-01-01T00:00:00'

# --- Option state (set by _parse_args / _resolve_settings) -------------------
# The default box is NOT written here: it is `enter_default box` from
# lib/enter.sh, the one source setup.sh uses as well (ADR 0005, invariant 2).
OPT_BOX=""
OPT_DISTROBOX=""
OPT_TIMEOUT=""
OPT_HELP=0
CMD=()
DISTROBOX="" TIMEOUT="" INTERVAL=""

# --- Run state (first launch only) -------------------------------------------
INIT_LOG=""
LOGS_PID=""
FOLLOWER_GONE=""
PROGRESS_OPEN=0

# --- Usage -------------------------------------------------------------------
_usage() {
    local _box
    _box="$(enter_default box)"
    sed "s/@DEFAULT_BOX@/${_box}/" >&2 <<'EOF'
Usage: enter.sh [--box <name>] [--distrobox <path>] [--timeout <seconds>]
                [-- <command>...]

Enter the worktool dev box: `<distrobox> enter <box> [-- <command>...]`.
On the box's FIRST launch (never started: docker inspect State.StartedAt
is 0001-01-01), distrobox-init installs packages first; this prints what is
going on instead of two static lines:

  - a notice that it can take several minutes, `docker logs -f <box>` and
    the full init log ${XDG_CACHE_HOME:-~/.cache}/worktool/<box>-init.log;
  - every 10 s: the stage, the elapsed time and the latest init output
    line (overwritten in place on a terminal);
  - on a timeout or failure: the reason, the log path, its last 20 lines
    and the recovery (distrobox rm -f <box>, then open a new terminal),
    exit 1. The box is never stopped or removed.

  --box <name>          Box to enter (default: @DEFAULT_BOX@); a container name:
                        [A-Za-z0-9][A-Za-z0-9_.-]*.
  --distrobox <path>    Absolute path of the distrobox to run (default: the
                        one on PATH).
  --timeout <seconds>   First-launch timeout (default: 900 = 15 min, or
                        $WORKTOOL_INIT_TIMEOUT).
  -- <command>...       Run <command> in the box instead of a login shell.
  -h, --help            Show this help and exit.

Environment:
  WORKTOOL_INIT_TIMEOUT   default for --timeout (seconds)
  WORKTOOL_INIT_INTERVAL  seconds between progress lines (default 10)
EOF
}

# Refuse the command line: one line on stderr (the caller returns 2).
_usage_error() {
    printf 'enter.sh: %s (see --help)\n' "$1" >&2
}

# 0 when $1 is a positive decimal integer.
_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# --- Argument parsing --------------------------------------------------------

# Store option $1 (--box / --distrobox / --timeout) = value $2 after
# validating it. Returns 2 on an invalid value.
_set_opt() {
    local _ok=0 _expected
    case "$1" in
        --box)
            _expected="$(enter_expected box)"
            enter_value_ok box "$2" && _ok=1 && OPT_BOX="$2" ;;
        --distrobox)
            _expected="an absolute path to an executable file"
            [[ "$2" == /* && -f "$2" && -x "$2" ]] && _ok=1 && OPT_DISTROBOX="$2" ;;
        --timeout)
            _expected="a positive number of seconds"
            _positive_int "$2" && _ok=1 && OPT_TIMEOUT="$2" ;;
    esac
    if [[ "${_ok}" -ne 1 ]]; then
        _usage_error "invalid value '$2' for $1 (expected ${_expected})"
        return 2
    fi
}

# Parse the WHOLE command line before anything runs; everything after `--`
# is the in-box command. Returns 2 on a usage error.
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --box|--distrobox|--timeout)
                if [[ $# -lt 2 ]]; then
                    _usage_error "$1 requires a value"
                    return 2
                fi
                _set_opt "$1" "$2" || return 2
                shift
                ;;
            --box=*|--distrobox=*|--timeout=*)
                _set_opt "${1%%=*}" "${1#*=}" || return 2
                ;;
            # Recorded, not served: `--help --bogus` is a usage error.
            -h|--help) OPT_HELP=1 ;;
            --)
                shift
                CMD=("$@")
                return 0
                ;;
            *)
                _usage_error "unknown option '$1'"
                return 2
                ;;
        esac
        shift
    done
}

# Resolve TIMEOUT / INTERVAL (exit status 2 on a bad environment value) and
# DISTROBOX (1 when there is none).
_resolve_settings() {
    TIMEOUT="${OPT_TIMEOUT:-${WORKTOOL_INIT_TIMEOUT:-${ENTER_DEFAULT_TIMEOUT}}}"
    INTERVAL="${WORKTOOL_INIT_INTERVAL:-${ENTER_DEFAULT_INTERVAL}}"
    if ! _positive_int "${TIMEOUT}"; then
        _usage_error "invalid value '${TIMEOUT}' for WORKTOOL_INIT_TIMEOUT (expected a positive number of seconds)"
        return 2
    fi
    if ! _positive_int "${INTERVAL}"; then
        _usage_error "invalid value '${INTERVAL}' for WORKTOOL_INIT_INTERVAL (expected a positive number of seconds)"
        return 2
    fi
    if [[ -n "${OPT_DISTROBOX}" ]]; then
        DISTROBOX="${OPT_DISTROBOX}"
    elif ! DISTROBOX="$(enter_distrobox_program)"; then
        log_error "distrobox: not found on PATH (install distrobox, or pass --distrobox <path>)"
        return 1
    fi
}

# --- First-launch detection --------------------------------------------------

# 0 when box $1 exists and was never started. No docker, no such box or an
# engine error is "not a first launch": distrobox enter reports those itself.
_first_launch() {
    local _started
    command -v docker >/dev/null 2>&1 || return 1
    _started="$(docker inspect --type container -f '{{.State.StartedAt}}' "$1" 2>/dev/null)" \
        || return 1
    [[ "${_started}" == "${ENTER_ZERO_STARTED}"* ]]
}

# --- Formatting --------------------------------------------------------------

# $1 seconds as `9s` / `3m32s`.
_fmt_duration() {
    if [[ "$1" -lt 60 ]]; then
        printf '%ss\n' "$1"
    else
        printf '%sm%02ds\n' "$(($1 / 60))" "$(($1 % 60))"
    fi
}

# The current stage: the last `distrobox: <stage>` line of the init log
# (what distrobox-enter itself shows as a stage title), else `starting`.
_init_stage() {
    local _stage
    _stage="$(sed -n 's/\r$//; s/^distrobox: //p' "${INIT_LOG}" | tail -n 1)"
    printf '%s\n' "${_stage:-starting}"
}

# The latest init output line: the last non-empty line that is not xtrace
# (`+ ...`, which distrobox-enter drops too), cut to ENTER_LATEST_MAX
# characters so a progress line stays one terminal line.
_init_latest() {
    local _line
    _line="$(sed -e 's/\r$//' -e '/^+/d' -e '/^[[:space:]]*$/d' "${INIT_LOG}" | tail -n 1)"
    printf '%s\n' "${_line:0:${ENTER_LATEST_MAX}}"
}

# --- Progress output ---------------------------------------------------------

# Emit progress line $2 on stderr: on a TTY ($1 = 1) overwrite the current
# line in place (carriage return + erase line, no newline), else print it
# as a line of its own.
_progress_emit() {
    if [[ "$1" -eq 1 ]]; then
        printf '\r\033[K%s' "$2" >&2
        PROGRESS_OPEN=1
    else
        printf '%s\n' "$2" >&2
    fi
}

# Close an in-place progress line, so the next message starts on its own.
_progress_end() {
    if [[ "${PROGRESS_OPEN}" -eq 1 ]]; then
        printf '\n' >&2
        PROGRESS_OPEN=0
    fi
}

# One progress line for elapsed time $1.
_progress() {
    local _tty=0
    [[ -t 2 ]] && _tty=1
    _progress_emit "${_tty}" \
        "[INFO] first launch: $(_init_stage) - $(_fmt_duration "$1") elapsed - $(_init_latest)"
}

# --- Failure / interrupt / cleanup -------------------------------------------

# Report first-launch failure reason $1: reason, log, its tail, recovery.
_fail() {
    _progress_end
    log_error "first launch of box '${OPT_BOX}' failed: $1"
    log_error "init log: ${INIT_LOG}"
    log_error "last ${ENTER_TAIL_LINES} lines of the init log:"
    tail -n "${ENTER_TAIL_LINES}" "${INIT_LOG}" | sed 's/^/  | /' >&2
    log_error "the box was left as it is (not stopped, not removed); to start over: distrobox rm -f ${OPT_BOX}, then open a new terminal"
}

# Stop and reap the background log follower, if any.
_cleanup() {
    [[ -n "${LOGS_PID}" ]] || return 0
    # kill fails only when the follower is already gone, and wait returns
    # the follower's own (signal) status: neither is an error here.
    if ! kill "${LOGS_PID}" 2>/dev/null; then
        :
    fi
    if ! wait "${LOGS_PID}" 2>/dev/null; then
        :
    fi
    LOGS_PID=""
}

# Ctrl-C / SIGTERM mid-initialisation: clean up, say what keeps running,
# exit $1 (130 / 143).
_on_signal() {
    _progress_end
    _cleanup
    log_warn "interrupted: box '${OPT_BOX}' keeps initialising in the background (not stopped); follow it with: docker logs -f ${OPT_BOX}; init log: ${INIT_LOG}"
    trap - EXIT
    exit "$1"
}

# --- First launch ------------------------------------------------------------

# Print the reason initialisation cannot succeed any more, or return 1 when
# nothing is wrong (yet).
_init_problem() {
    local _error _running
    _error="$(grep -m 1 '^Error:' "${INIT_LOG}")" || _error=""
    if [[ -n "${_error}" ]]; then
        printf 'distrobox-init reported: %s\n' "${_error%$'\r'}"
        return 0
    fi
    _running="$(docker inspect --type container -f '{{.State.Running}}' "${OPT_BOX}" 2>/dev/null)" \
        || _running="unknown"
    if [[ "${_running}" != "true" ]]; then
        printf 'the container stopped during initialisation (State.Running=%s)\n' "${_running}"
        return 0
    fi
    return 1
}

# Sample the background `docker logs -f` follower: while it runs FOLLOWER_GONE
# stays empty; once it is gone it is reaped and FOLLOWER_GONE says why.
# Without this check a follower that died early (engine error, permission,
# lost connection) never delivers container_setup_done and the wait ends as
# a false timeout. Runs in the main shell (never in $(...)): only the parent
# can reap its own background job.
_follower_check() {
    local _status=0
    FOLLOWER_GONE=""
    kill -0 "${LOGS_PID}" 2>/dev/null && return 0
    wait "${LOGS_PID}" 2>/dev/null || _status=$?
    LOGS_PID=""
    FOLLOWER_GONE="the log follower (docker logs -f ${OPT_BOX}) exited with status ${_status} before container_setup_done"
}

# Poll the init log once a second until setup is done (0), something failed
# or the timeout passed (1, reported). A progress line every INTERVAL s.
# The follower's liveness is sampled BEFORE the log is read, so the last
# lines of a follower that just ended (container_setup_done included) are
# always seen before it counts as gone.
_wait_for_setup() {
    local _start="${SECONDS}" _elapsed _next="${INTERVAL}" _reason
    while :; do
        _elapsed=$((SECONDS - _start))
        [[ -z "${LOGS_PID}" ]] || _follower_check
        if grep -q 'container_setup_done' "${INIT_LOG}"; then
            _progress_end
            log_info "first launch: initialisation complete after $(_fmt_duration "${_elapsed}") - entering the box"
            return 0
        fi
        if _reason="$(_init_problem)"; then
            _fail "${_reason}"
            return 1
        fi
        if [[ -n "${FOLLOWER_GONE}" ]]; then
            _fail "${FOLLOWER_GONE}"
            return 1
        fi
        if [[ "${_elapsed}" -ge "${TIMEOUT}" ]]; then
            _fail "timed out after $(_fmt_duration "${TIMEOUT}") without container_setup_done (the box may still be installing: docker logs -f ${OPT_BOX})"
            return 1
        fi
        if [[ "${_elapsed}" -ge "${_next}" ]]; then
            _progress "${_elapsed}"
            _next=$(((_elapsed / INTERVAL + 1) * INTERVAL))
        fi
        sleep 1
    done
}

# Create the host init log and say what is about to happen. Returns 1 when
# the log cannot be created.
_init_notice() {
    INIT_LOG="${XDG_CACHE_HOME:-${HOME}/.cache}/worktool/${OPT_BOX}-init.log"
    if ! mkdir -p "$(dirname -- "${INIT_LOG}")" || ! : >"${INIT_LOG}"; then
        log_error "cannot create the init log ${INIT_LOG}"
        return 1
    fi
    log_info "first launch of box '${OPT_BOX}': distrobox installs its packages first - this can take several minutes (timeout $(_fmt_duration "${TIMEOUT}"))"
    log_info "follow the full output in another terminal: docker logs -f ${OPT_BOX}"
    log_info "full init log: ${INIT_LOG}"
}

# Start the never-started box, follow its log and wait for setup to finish.
# Returns 1 (already reported) on any failure; the follower is gone either
# way.
_first_init() {
    local _rc=0
    _init_notice || return 1
    trap '_on_signal 130' INT
    trap '_on_signal 143' TERM
    trap _cleanup EXIT
    if ! docker start "${OPT_BOX}" >>"${INIT_LOG}" 2>&1; then
        _fail "docker start ${OPT_BOX} failed"
        return 1
    fi
    docker logs -f "${OPT_BOX}" >>"${INIT_LOG}" 2>&1 &
    LOGS_PID=$!
    _wait_for_setup || _rc=$?
    _cleanup
    trap - INT TERM EXIT
    return "${_rc}"
}

# --- Main --------------------------------------------------------------------
enter_run() {
    local _rc=0 _argv
    _parse_args "$@" || return 2
    [[ -n "${OPT_BOX}" ]] || OPT_BOX="$(enter_default box)"
    if [[ "${OPT_HELP}" -eq 1 ]]; then
        _usage
        return 0
    fi
    _resolve_settings || _rc=$?
    [[ "${_rc}" -eq 0 ]] || return "${_rc}"
    if _first_launch "${OPT_BOX}"; then
        _first_init || return 1
    fi
    _argv=(enter "${OPT_BOX}")
    if [[ "${#CMD[@]}" -gt 0 ]]; then
        _argv+=(-- "${CMD[@]}")
    fi
    exec "${DISTROBOX}" "${_argv[@]}"
}

# Guard: only run when executed directly, not when sourced (keeps the file
# importable by tests).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    enter_run "$@"
fi
