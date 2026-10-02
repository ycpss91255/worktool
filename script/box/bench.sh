#!/usr/bin/env bash
# bench.sh - measure the enter latency of a worktool box (M3, issues #150,
# #162 and #181).
#
# Times setup's managed command (through enter.sh) plus a metric payload
# with bash's EPOCHREALTIME (microsecond wall clock; no hyperfine, nothing to install) and reports min / median /
# max in milliseconds for three metrics (the unit tests swap the clock for
# an injected one through the test-only BENCH_CLOCK, issue #249; see
# _now_us):
#
#   enter   <managed-command> -- true          (wrapper + engine round trip)
#   shell   <managed-command> -- <shell>       (the same, plus a shell
#                                                   start-up; default `sh -c :`)
#   inbox   <managed-command> -- bash -c '<timer>' bench-inbox <shell>
#                                                  (the shell start-up ALONE,
#                                                   clocked inside the box)
#
# enter and shell are clocked on the host around the whole round trip. inbox
# is not: the box runs a one-line bash timer (INBOX_TIMER below) that reads
# its own EPOCHREALTIME before and after <shell> and prints the difference in
# microseconds as its last stdout line; bench.sh parses that number, so the
# enter round trip is NOT part of it (shell - inbox ~ enter). A timer that
# prints anything but an integer aborts the measurement like a failing run.
#
# Every metric runs --warmup unrecorded times first (the first enter may
# start a stopped container), then --runs recorded times, in the order
# enter, shell, inbox. --max-ms N turns the tool into a gate: exit 1 when
# the SHELL median exceeds N ms (the user-perceived time to a prompt); the
# other two metrics are reported, not judged. The < 300 ms target itself and
# the runtime decision (runc / crun) live in issue #22, not here.
#
# Quiet-host precondition (issue #181, doc/adr/0003-latency-gate-inconclusive.md):
# a wall-clock number taken on a busy host is not evidence either way, so
# before the first run the script waits until CPU pressure (PSI) `some
# avg10 <= 2.00` has held for 5 consecutive seconds (one poll a second),
# read from this process's own cgroup v2 cpu.pressure, else from
# /proc/pressure/cpu. It waits at most --max-wait seconds (60, or 120 when
# CI is set); a host that does not get quiet in time is exit 3
# (inconclusive: no verdict, nothing on stdout, distrobox never called).
# PSI is read again and recorded (one stderr line: `psi before|after
# <metric> run <k>: <path> some avg10=<value>`) before and after every
# run, a failed run included; one reading above the limit voids the whole
# batch (exit 3, even when that run also failed; slow samples are never
# dropped). The limit is exact at any number of decimals: 2.001 is busy.
# loadavg is printed next to every PSI verdict as evidence and never
# decides. When no PSI file is readable (a kernel without PSI), a warning
# says so and the measurement runs unguarded rather than never at all.
#
# The backing script of `just box bench` (script/box/justfile.box forwards
# the arguments here verbatim); it also runs on its own:
#
#   ./script/box/bench.sh                          # dev box, 2 warmup + 10 runs
#   ./script/box/bench.sh --runs 3 --warmup 1      # quicker
#   ./script/box/bench.sh --max-ms 300             # gate: exit 1 above 300 ms
#   ./script/box/bench.sh --max-wait 30            # give up (exit 3) sooner
#   ./script/box/bench.sh --json                   # one JSON object instead
#   ./script/box/bench.sh --shell 'fish -c exit'   # time another shell
#   ./script/box/bench.sh --help                   # usage
#
# Output (stdout, machine-readable; diagnostics go to stderr via lib/log.sh):
#
#   enter: min=<ms> median=<ms> max=<ms> ms
#   shell: min=<ms> median=<ms> max=<ms> ms
#   inbox: min=<ms> median=<ms> max=<ms> ms
#
# or, with --json, exactly one object:
#
#   {"box":"dev","runs":10,"warmup":2,"shell_cmd":"sh -c :","unit":"ms",
#    "enter":{"min":..,"median":..,"max":..},"shell":{...},"inbox":{...}}
#
# The object is ALWAYS valid JSON, guaranteed by input validation rather
# than by a full JSON escaper: --box must match ^[A-Za-z0-9._-]+$ and
# --shell must not contain a control character (newline, tab, escape, ...);
# a backslash or double quote in --shell is legal and escaped in shell_cmd.
#
# This script owns its option validation: the WHOLE command line is parsed
# before anything runs, so an unknown option anywhere in it is refused with
# `bench.sh: unknown option '<x>' (see --help)` on stderr, exit 2, and
# distrobox is never called (an invalid --box / --shell value is refused
# the same way: `bench.sh: invalid --box ... (see --help)`); --help is
# served only after that. A run of the measured command that exits non-zero
# aborts the measurement (exit 1) - a failing enter has no latency worth
# reporting.
#
# Exit codes: 0 ok (and within --max-ms), 1 measurement failed or the shell
# median exceeds --max-ms, 2 usage error, 3 inconclusive (the host was not
# quiet within --max-wait, or turned busy mid-run), 127 distrobox not on
# PATH.
#
# Guards: `set -euo pipefail` (doc/adr/0001-scripts-use-errexit.md): an
# unhandled failure stops the script at once. A non-zero status the script
# EXPECTS is handled explicitly (`if ! cmd`, `cmd || _rc=$?`), never
# swallowed with `|| true`, so every exit code documented here stays the
# script's own.

# `source=` directives below resolve against lib/ (SCRIPTDIR/../../lib: the
# repo root is two levels up from script/box/). This file-wide directive
# must precede the first command (set) to take effect.
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

# --- Defaults (overridden by the command line; see _parse_args) --------------
OPT_BOX="dev"
OPT_RUNS=10
OPT_WARMUP=2
OPT_MAX_MS=""          # empty = no gate
OPT_JSON=0
OPT_SHELL="sh -c :"
OPT_MAX_WAIT=""        # empty = 60, or 120 when CI is set (_default_max_wait)
OPT_HELP=0

# --- Quiet-host precondition (issue #181) ------------------------------------
PSI_LIMIT="2.00"       # `some avg10` limit, compared exactly (_dec_le)
PSI_QUIET_S=5          # consecutive quiet seconds before the first run
# Where the PSI comes from. BENCH_PSI_FILE (environment, tests only)
# replaces the whole lookup below.
CGROUP_FS="/sys/fs/cgroup"
PROC_SELF_CGROUP="/proc/self/cgroup"
PROC_PSI="/proc/pressure/cpu"
LOADAVG_FILE="/proc/loadavg"
PSI_PATH=""            # the PSI file in use; empty = none readable
PSI_VAL=""             # last `some avg10`, as printed; empty = no reading
PSI_PEAK=""            # highest reading of the batch, as printed
LOADAVG="n/a"

# --- Input validation rules (what keeps --json valid JSON) -------------------
BOX_NAME_RE='^[A-Za-z0-9._-]+$'
CONTROL_CHAR_RE='[[:cntrl:]]'

# --- The in-box timer (inbox metric) -----------------------------------------
# ONE line of bash, run inside the box as `bash -c "${INBOX_TIMER}"
# bench-inbox <shell>...` so the shell command arrives as "$@" with its argv
# boundaries intact ($0 is the name `bench-inbox`). It reads the box's own
# EPOCHREALTIME before and after the shell command (the radix follows the
# locale: `,` is normalised to `.`), prints the difference in microseconds
# as its last stdout line and exits with the shell command's status. The
# shell command's stdout is discarded so the number is the last line. The
# `:?` guard turns a box whose bash lacks EPOCHREALTIME (< 5.0) into a
# non-zero exit with a message instead of a bogus number. Held verbatim
# (quoted heredoc, one line): nothing in it expands on the host.
IFS= read -r INBOX_TIMER <<'EOF'
t0=${EPOCHREALTIME/,/.}; : "${t0:?bash 5+ is needed inside the box}"; "$@" >/dev/null; rc=$?; t1=${EPOCHREALTIME/,/.}; echo $(( 10#${t1%.*} * 1000000 + 10#${t1#*.} - 10#${t0%.*} * 1000000 - 10#${t0#*.} )); exit $rc
EOF

# --- Usage -------------------------------------------------------------------
_usage() {
    cat >&2 <<'EOF'
Usage: bench.sh [--box NAME] [--runs N] [--warmup N] [--max-ms N] [--json]
                [--shell CMD] [--max-wait N] [-h|--help]

Measure the enter latency of a worktool box with bash EPOCHREALTIME.
Setup writes the managed terminal command in a temporary config (not timed).
Every metric executes that command through enter.sh; user config is untouched:

  enter   <managed-command> -- true                 (host-clocked)
  shell   <managed-command> -- <shell>              (host-clocked)
  inbox   <managed-command> -- bash -c '<timer>' bench-inbox <shell>
          (<shell> clocked INSIDE the box: its start-up without the enter)

Each metric runs --warmup unrecorded times, then --runs recorded times, and
prints `<metric>: min=<ms> median=<ms> max=<ms> ms` (one line each).

  --box NAME     Box to enter (default: dev). Letters, digits, `.`, `_`
                 and `-` only.
  --runs N       Recorded runs per metric, N >= 1 (default: 10).
  --warmup N     Unrecorded runs per metric before measuring, N >= 0
                 (default: 2).
  --max-ms N     Exit 1 when the shell median exceeds N milliseconds
                 (default: no threshold; the target lives in issue #22).
  --json         Print one JSON object instead of the three text lines.
  --shell CMD    Command for the shell and inbox metrics, word-split
                 (default: sh -c :). No control characters (newline, tab).
  --max-wait N   Wait at most N seconds, N >= 1, for a quiet host before
                 measuring (default: 60; 120 when CI is set).
  -h, --help     Show this help and exit.

Quiet host: measuring starts once CPU pressure (PSI) some avg10 <= 2.00
has held for 5 consecutive seconds, read from this process's cgroup v2
cpu.pressure, else /proc/pressure/cpu (the path read is printed; loadavg
is printed too, it never decides). PSI is read again and recorded on
stderr before and after every run, a failed one included: one reading
above the limit voids the whole batch (exit 3, even over a failed run).
The limit is exact (2.001 is above it). No readable PSI: a warning, and
the measurement runs unguarded.

Exit codes:
  0    measured, and the shell median is within --max-ms (if given)
  1    a run failed, or the shell median exceeds --max-ms
  2    usage error
  3    inconclusive: the host was not quiet within --max-wait, or turned
       busy mid-run (no verdict, no metric line)
  127  distrobox not on PATH

Environment (tests only):
  BENCH_PSI_FILE  read the PSI from this file instead of the cgroup /
                  /proc/pressure/cpu lookup.
  BENCH_CLOCK     run this program for the host clock (it prints the time
                  in microseconds) instead of reading EPOCHREALTIME; a
                  failing clock or a non-integer aborts the run (exit 1).
EOF
}

# Refuse the command line: one line on stderr (the caller returns 2; nothing
# has run yet).
_usage_error() {
    printf 'bench.sh: %s (see --help)\n' "$1" >&2
}

# --- Option parsing ----------------------------------------------------------

# Refuse $2 (the value of option $1) unless it is an integer >= $3.
_check_int_min() {
    if [[ ! "$2" =~ ^[0-9]+$ ]] || (( 10#$2 < $3 )); then
        _usage_error "$1 requires an integer >= $3, got '$2'"
        return 2
    fi
}

# Refuse the --box value $1 unless it matches BOX_NAME_RE (what keeps the
# JSON string and the distrobox argv trivially safe). The value is echoed
# %q-quoted so the message stays one line whatever the value holds.
_check_box() {
    [[ -n "$1" ]] || { _usage_error "--box requires a non-empty name"; return 2; }
    if [[ ! "$1" =~ ${BOX_NAME_RE} ]]; then
        local _q
        printf -v _q '%q' "$1"
        _usage_error "invalid --box ${_q}: only letters, digits, '.', '_' and '-' are allowed"
        return 2
    fi
}

# Refuse the --shell value $1 when it is empty or holds a control character
# (a raw newline or tab would break the --json object; a backslash or a
# double quote is fine, they are escaped). %q-quoted in the message for the
# same one-line reason as _check_box.
_check_shell() {
    [[ -n "$1" ]] || { _usage_error "--shell requires a non-empty command"; return 2; }
    if [[ "$1" =~ ${CONTROL_CHAR_RE} ]]; then
        local _q
        printf -v _q '%q' "$1"
        _usage_error "invalid --shell ${_q}: control characters are not allowed"
        return 2
    fi
}

# Store the value $2 of the value-taking option $1 after validating it.
_set_opt() {
    case "$1" in
        --box)    _check_box "$2" || return 2; OPT_BOX="$2" ;;
        --shell)  _check_shell "$2" || return 2; OPT_SHELL="$2" ;;
        --runs)   _check_int_min "$1" "$2" 1 || return 2; OPT_RUNS=$(( 10#$2 )) ;;
        --warmup) _check_int_min "$1" "$2" 0 || return 2; OPT_WARMUP=$(( 10#$2 )) ;;
        --max-ms) _check_int_min "$1" "$2" 1 || return 2; OPT_MAX_MS=$(( 10#$2 )) ;;
        --max-wait) _check_int_min "$1" "$2" 1 || return 2; OPT_MAX_WAIT=$(( 10#$2 )) ;;
    esac
}

# Parse the WHOLE command line into the OPT_* globals before anything runs,
# so an unknown option anywhere in it refuses the run as a whole. Returns 2
# on a usage error (message already printed).
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --box|--runs|--warmup|--max-ms|--shell|--max-wait)
                if [[ $# -lt 2 ]]; then
                    _usage_error "$1 requires an argument"
                    return 2
                fi
                _set_opt "$1" "$2" || return 2
                shift
                ;;
            --box=*|--runs=*|--warmup=*|--max-ms=*|--shell=*|--max-wait=*)
                _set_opt "${1%%=*}" "${1#*=}" || return 2
                ;;
            --json) OPT_JSON=1 ;;
            # Recorded, not served: `--help --bogus` is a usage error.
            -h|--help) OPT_HELP=1 ;;
            *)
                _usage_error "unknown option '$1'"
                return 2
                ;;
        esac
        shift
    done
}

# --- Timing ------------------------------------------------------------------

# Store the host clock in microseconds in the variable named $1. The real
# clock is EPOCHREALTIME ("<seconds>.<6 digits>", the radix follows the
# locale), read with no subshell: a $(...) fork would add its own latency
# to every sample. BENCH_CLOCK (environment, tests only, issue #249)
# replaces it with a program that prints the time in microseconds, so the
# unit tests decide on injected times instead of the host's load.
_now_us() {
    local -n _ref_now="$1"
    if [[ -n "${BENCH_CLOCK:-}" ]]; then
        _bench_clock_us _ref_now
        return
    fi
    local _t="${EPOCHREALTIME/,/.}"
    _ref_now=$(( 10#${_t%.*} * 1000000 + 10#${_t#*.} ))
}

# Store what the test-only BENCH_CLOCK program prints (microseconds) in the
# variable named $1. A clock that fails or prints anything but an integer
# is refused (return 1, RUN_ERR set): a bogus time must never become a
# sample.
_bench_clock_us() {
    local -n _ref_clk="$1"
    local _out _rc=0
    _out="$("${BENCH_CLOCK}" </dev/null)" || _rc=$?
    if (( _rc != 0 )); then
        RUN_ERR="BENCH_CLOCK '${BENCH_CLOCK}' exited ${_rc}"
        return 1
    fi
    if [[ ! "${_out}" =~ ^[0-9]+$ ]]; then
        RUN_ERR="BENCH_CLOCK '${BENCH_CLOCK}' printed '${_out}' instead of an integer"
        return 1
    fi
    _ref_clk=$(( 10#${_out} ))
}

# Run the command $2.. once with stdin/stdout closed off (stderr passes
# through: it is diagnostics), store its wall time in microseconds in the
# variable named $1, and return the command's exit status.
_time_cmd() {
    local -n _ref_us="$1"
    shift
    local _t0 _t1 _rc
    _now_us _t0 || return 1
    _rc=0
    "$@" </dev/null >/dev/null || _rc=$?
    _now_us _t1 || return 1
    _ref_us=$(( _t1 - _t0 ))
    return "${_rc}"
}

# Why the last run failed when the runner itself refused it (set by
# _inbox_cmd; empty means "the command exited non-zero", which _run_metric
# words itself).
RUN_ERR=""

# The inbox runner, same contract as _time_cmd (store microseconds in the
# variable named $1, return the command's status) but the number is what
# the in-box timer $2.. PRINTED as its last stdout line, not a host clock.
# A last line that is not an integer is refused (return 1, RUN_ERR set).
_inbox_cmd() {
    local -n _ref_us="$1"
    shift
    local _out _rc=0
    _out="$("$@" </dev/null)" || _rc=$?
    (( _rc == 0 )) || return "${_rc}"
    _out="${_out##*$'\n'}"
    if [[ ! "${_out}" =~ ^[0-9]+$ ]]; then
        RUN_ERR="the in-box timer printed '${_out}' instead of an integer"
        return 1
    fi
    _ref_us=$(( 10#${_out} ))
}

# Time metric $1: OPT_WARMUP unrecorded runs, then OPT_RUNS recorded ones
# appended (microseconds) to the array named $2, each run made by the
# runner $3 (_time_cmd or _inbox_cmd) on the command $4... The first run
# that fails aborts the metric (return 1) unless the PSI reading after it
# is above the limit: a reading above the limit before or after any run
# (failed or not) voids the batch (return 3), and wins over the failure. Diagnostics show the in-box
# timer as `<timer>` (as --help does), not its one-line source.
_run_metric() {
    local _name="$1" _runner="$3"
    local -n _ref_samples="$2"
    shift 3
    local _i _us _rc _shown="$*"
    # The shell adapter executes setup's source verbatim; report that source
    # and the payload rather than the adapter's own argv.
    if [[ -n "${MANAGED_COMMAND:-}" ]]; then
        _shown="${MANAGED_COMMAND} -- ${*:5}"
    fi
    _shown="${_shown//"${INBOX_TIMER}"/<timer>}"
    for (( _i = 0; _i < OPT_WARMUP + OPT_RUNS; _i++ )); do
        _psi_guard "before ${_name} run $(( _i + 1 ))" || return 3
        RUN_ERR=""
        _rc=0
        "${_runner}" _us "$@" || _rc=$?
        # The after-run check comes FIRST, whatever the run returned: a
        # run that failed on a host that turned busy during it is no
        # evidence of a broken box - the batch is void (3), not failed (1).
        _psi_guard "after ${_name} run $(( _i + 1 ))" || return 3
        if (( _rc != 0 )); then
            log_error "${_name}: ${RUN_ERR:-"'${_shown}' exited ${_rc}"} on run $(( _i + 1 )) - measurement aborted"
            return 1
        fi
        (( _i >= OPT_WARMUP )) && _ref_samples+=("${_us}")
    done
    log_info "${_name}: ${OPT_WARMUP} warmup + ${OPT_RUNS} run(s) of '${_shown}' done"
    return 0
}

# --- Quiet host: PSI and loadavg (issue #181) --------------------------------

# Return 0 when the decimal number $1 <= the decimal number $2, compared
# EXACTLY at any number of decimals (2.001 > 2.00; nothing is truncated).
# Both must match ^[0-9]+(\.[0-9]+)?$ (_psi_read validated them): the
# integer parts are compared as digit strings without leading zeros (by
# length, then lexically), the fractions padded with zeros to one length
# and compared lexically - equal-length digit strings order like numbers.
_dec_le() {
    local _ai="${1%%.*}" _bi="${2%%.*}" _af="" _bf=""
    [[ "$1" == *.* ]] && _af="${1#*.}"
    [[ "$2" == *.* ]] && _bf="${2#*.}"
    _ai="${_ai#"${_ai%%[!0]*}"}"
    _bi="${_bi#"${_bi%%[!0]*}"}"
    if (( ${#_ai} != ${#_bi} )); then
        (( ${#_ai} < ${#_bi} ))
        return
    fi
    if [[ "${_ai}" != "${_bi}" ]]; then
        [[ "${_ai}" < "${_bi}" ]]
        return
    fi
    while (( ${#_af} < ${#_bf} )); do _af+="0"; done
    while (( ${#_bf} < ${#_af} )); do _bf+="0"; done
    [[ ! "${_af}" > "${_bf}" ]]
}

# Read `some avg10` from the PSI file $1 into PSI_VAL (as printed, after
# checking it is a plain decimal number). PSI_VAL is cleared first, so a
# failed read never leaves the previous reading behind. Returns 1 when the
# file is unreadable or has no such line.
_psi_read() {
    local _line _re='^some avg10=([0-9]+(\.[0-9]+)?)( |$)'
    PSI_VAL=""
    [[ -r "$1" ]] || return 1
    while IFS= read -r _line; do
        if [[ "${_line}" =~ ${_re} ]]; then
            PSI_VAL="${BASH_REMATCH[1]}"
            return 0
        fi
    done 2>/dev/null <"$1"
    return 1
}

# Return 0 when the last reading (PSI_VAL) is within the limit.
_psi_quiet() {
    [[ -n "${PSI_VAL}" ]] && _dec_le "${PSI_VAL}" "${PSI_LIMIT}"
}

# Set PSI_PATH to the first PSI file that yields a reading: BENCH_PSI_FILE
# when set (tests only), else this process's own cgroup v2 cpu.pressure,
# else PROC_PSI. PSI_PATH stays empty when none does.
_psi_resolve() {
    PSI_PATH=""
    if [[ -n "${BENCH_PSI_FILE+set}" ]]; then
        if _psi_read "${BENCH_PSI_FILE}"; then PSI_PATH="${BENCH_PSI_FILE}"; fi
        return 0
    fi
    local _line _rel=""
    if [[ -r "${PROC_SELF_CGROUP}" ]]; then
        while IFS= read -r _line; do
            if [[ "${_line}" == 0::* ]]; then _rel="${_line#0::}"; fi
        done <"${PROC_SELF_CGROUP}"
    fi
    local _cg="${CGROUP_FS}${_rel%/}/cpu.pressure"
    if [[ -n "${_rel}" ]] && _psi_read "${_cg}"; then
        PSI_PATH="${_cg}"
    elif _psi_read "${PROC_PSI}"; then
        PSI_PATH="${PROC_PSI}"
    fi
}

# Set LOADAVG to the 1 / 5 / 15 minute load averages ("n/a" when
# unreadable). Recorded as evidence next to every PSI verdict, never judged.
_loadavg() {
    local _a _b _c _rest
    LOADAVG="n/a"
    if [[ -r "${LOADAVG_FILE}" ]] && read -r _a _b _c _rest <"${LOADAVG_FILE}"; then
        LOADAVG="${_a} ${_b} ${_c}"
    fi
}

# Wait, polling PSI once a second, until `some avg10 <= 2.00` has held for
# PSI_QUIET_S consecutive seconds (readings at t .. t + PSI_QUIET_S).
# Return 3 (inconclusive) once OPT_MAX_WAIT seconds have passed without it.
_wait_quiet() {
    local _streak=-1 _waited=0
    while :; do
        if _psi_read "${PSI_PATH}" && _psi_quiet; then
            _streak=$(( _streak + 1 ))
        else
            _streak=-1
        fi
        if (( _streak >= PSI_QUIET_S )); then
            _loadavg
            log_info "host quiet: ${PSI_PATH} some avg10=${PSI_VAL} <= 2.00 for ${PSI_QUIET_S}s; loadavg=${LOADAVG}"
            return 0
        fi
        if (( _waited >= OPT_MAX_WAIT )); then
            _loadavg
            log_error "host too busy to measure (inconclusive): ${PSI_PATH} some avg10=${PSI_VAL:-?} for ${_waited}s; loadavg=${LOADAVG}; re-run when idle"
            return 3
        fi
        sleep 1
        _waited=$(( _waited + 1 ))
    done
}

# The precondition before the first run: find the PSI, then wait for a
# quiet host (return 3 when it does not come). No readable PSI is said
# out loud and measured unguarded - never a silent pass, never a hang.
_host_precondition() {
    _psi_resolve
    if [[ -z "${PSI_PATH}" ]]; then
        _loadavg
        log_warn "no CPU pressure (PSI) readable (cgroup v2 cpu.pressure, ${PROC_PSI}) - quiet-host check skipped, measuring anyway; loadavg=${LOADAVG}"
        return 0
    fi
    _wait_quiet
}

# Read PSI at the sample boundary $1 names ("before enter run 3"), record
# it (one stderr line: the boundary, the path and the value) and return 3 -
# the whole batch is void - when it is above the limit or unreadable.
# Tracks the batch's peak reading. A no-op when no PSI is in use.
_psi_guard() {
    [[ -n "${PSI_PATH}" ]] || return 0
    if _psi_read "${PSI_PATH}" && _psi_quiet; then
        log_info "psi $1: ${PSI_PATH} some avg10=${PSI_VAL}"
        if [[ -z "${PSI_PEAK}" ]] || ! _dec_le "${PSI_VAL}" "${PSI_PEAK}"; then
            PSI_PEAK="${PSI_VAL}"
        fi
        return 0
    fi
    _loadavg
    log_error "host too busy mid-run (inconclusive): ${PSI_PATH} some avg10=${PSI_VAL:-?} $1; loadavg=${LOADAVG}; batch void, re-run when idle"
    return 3
}

# --- Statistics and output ---------------------------------------------------

# Store "min median max" (microseconds) of the samples in the array named
# $1 into the array named $2. The median of an even count is the mean of
# the two middle samples.
_stats() {
    local -n _ref_s="$1"
    local -n _ref_out="$2"
    local -a _sorted
    mapfile -t _sorted < <(printf '%s\n' "${_ref_s[@]}" | sort -n)
    local _n="${#_sorted[@]}" _median
    if (( _n % 2 == 1 )); then
        _median="${_sorted[_n / 2]}"
    else
        _median=$(( (_sorted[_n / 2 - 1] + _sorted[_n / 2]) / 2 ))
    fi
    _ref_out=("${_sorted[0]}" "${_median}" "${_sorted[_n - 1]}")
}

# Print microseconds $1 as milliseconds with one decimal (truncated).
_fmt_ms() {
    printf '%d.%d' $(( $1 / 1000 )) $(( ($1 % 1000) / 100 ))
}

# Print the text line of metric $1 from "min median max" microseconds $2 $3 $4.
_print_text() {
    printf '%s: min=%s median=%s max=%s ms\n' \
        "$1" "$(_fmt_ms "$2")" "$(_fmt_ms "$3")" "$(_fmt_ms "$4")"
}

# Print $1 as a JSON string (backslash and double quote escaped). Enough
# because _check_box / _check_shell refused every control character before
# anything ran; there is no other string in the object.
_json_str() {
    local _s="${1//\\/\\\\}"
    _s="${_s//\"/\\\"}"
    printf '"%s"' "${_s}"
}

# Print the JSON object of one metric from "min median max" microseconds.
_json_metric() {
    printf '{"min":%s,"median":%s,"max":%s}' \
        "$(_fmt_ms "$1")" "$(_fmt_ms "$2")" "$(_fmt_ms "$3")"
}

# Print the one-object JSON report from the enter, shell and inbox stats
# arrays named $1, $2 and $3 ("min median max" microseconds each).
_print_json() {
    local -n _ref_e="$1"
    local -n _ref_sh="$2"
    local -n _ref_in="$3"
    printf '{"box":%s,"runs":%s,"warmup":%s,"shell_cmd":%s,"unit":"ms","enter":%s,"shell":%s,"inbox":%s}\n' \
        "$(_json_str "${OPT_BOX}")" "${OPT_RUNS}" "${OPT_WARMUP}" \
        "$(_json_str "${OPT_SHELL}")" \
        "$(_json_metric "${_ref_e[@]}")" "$(_json_metric "${_ref_sh[@]}")" \
        "$(_json_metric "${_ref_in[@]}")"
}

# Apply --max-ms to the shell median (microseconds, $1): return 1 above it.
_check_threshold() {
    [[ -n "${OPT_MAX_MS}" ]] || return 0
    if (( $1 > OPT_MAX_MS * 1000 )); then
        log_error "shell median $(_fmt_ms "$1") ms exceeds --max-ms ${OPT_MAX_MS}"
        return 1
    fi
    log_info "shell median $(_fmt_ms "$1") ms within --max-ms ${OPT_MAX_MS}"
    return 0
}

# --- Main --------------------------------------------------------------------

# Run the real setup in an isolated config, outside the timed path. Read the
# resulting terminal command rather than reconstructing its wrapper argv.
# No user config is changed, including the test-only config override.
_managed_command() (
    local _tmp _body
    _tmp="$(mktemp -d)" || return 1
    trap 'rm -rf -- "${_tmp}"' EXIT
    export XDG_CONFIG_HOME="${_tmp}"
    unset WORKTOOL_CONFIG_FILE
    "${SCRIPT_DIR}/setup.sh" --auto-enter yes --terminal ghostty \
        --box "${OPT_BOX}" >/dev/null || return 1
    _body="$(enter_block_body "$(enter_ghostty_target)")" || return 1
    if [[ "${_body}" != 'command = '* || "${_body}" == 'command = ' ]]; then
        log_error "setup did not write a managed command - cannot bench"
        return 1
    fi
    printf '%s\n' "${_body#command = }"
)

# Wait for a quiet host, measure the three metrics (enter, shell, inbox)
# and report. Runs only after the command line was fully validated.
_bench_exec() {
    if ! command -v distrobox >/dev/null 2>&1; then
        log_error "distrobox not found on PATH - cannot bench"
        return 127
    fi
    local -a _shell_argv _enter_us=() _shell_us=() _inbox_us=()
    local -a _e_stats _s_stats _i_stats
    read -r -a _shell_argv <<<"${OPT_SHELL}"
    MANAGED_COMMAND="$(_managed_command)" || return 1
    # Ghostty executes this shell source; append only the metric payload,
    # with argv boundaries preserved across the shell and enter wrapper.
    local -a _managed=(sh -c "${MANAGED_COMMAND} -- \"\$@\"" bench-managed)
    _host_precondition || return $?

    _run_metric enter _enter_us _time_cmd \
        "${_managed[@]}" true || return $?
    _run_metric shell _shell_us _time_cmd \
        "${_managed[@]}" "${_shell_argv[@]}" || return $?
    _run_metric inbox _inbox_us _inbox_cmd \
        "${_managed[@]}" bash -c "${INBOX_TIMER}" bench-inbox "${_shell_argv[@]}" || return $?
    if [[ -n "${PSI_PATH}" ]]; then
        _loadavg
        log_info "host stayed quiet: ${PSI_PATH} some avg10 peak=${PSI_PEAK} over every run; loadavg=${LOADAVG}"
    fi

    _stats _enter_us _e_stats
    _stats _shell_us _s_stats
    _stats _inbox_us _i_stats
    if (( OPT_JSON )); then
        _print_json _e_stats _s_stats _i_stats
    else
        _print_text enter "${_e_stats[@]}"
        _print_text shell "${_s_stats[@]}"
        _print_text inbox "${_i_stats[@]}"
    fi
    _check_threshold "${_s_stats[1]}"
}

# Default --max-wait: 60 s, or 120 s on CI (a shared runner may need
# longer to settle; a busy one is still exit 3, never skipped).
_default_max_wait() {
    [[ -z "${OPT_MAX_WAIT}" ]] || return 0
    if [[ -n "${CI:-}" ]]; then
        OPT_MAX_WAIT=120
    else
        OPT_MAX_WAIT=60
    fi
}

bench_run() {
    _parse_args "$@" || return 2
    _default_max_wait
    if (( OPT_HELP )); then
        _usage
        return 0
    fi
    if [[ -z "${EPOCHREALTIME:-}" ]]; then
        log_error "bash 5+ is required (EPOCHREALTIME is not available)"
        return 1
    fi
    _bench_exec
}

# Guard: only run when executed directly, not when sourced (keeps the file
# importable by tests).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    bench_run "$@"
fi
