#!/usr/bin/env bash
# bench.sh - measure the enter latency of a worktool box (M3, issue #150).
#
# Times `distrobox enter <box> -- ...` with bash's EPOCHREALTIME (microsecond
# wall clock; no hyperfine, nothing to install) and reports min / median /
# max in milliseconds for two metrics:
#
#   enter   distrobox enter <box> -- true          (wrapper + engine round trip)
#   shell   distrobox enter <box> -- <shell>       (the same, plus a shell
#                                                   start-up; default `sh -c :`)
#
# Every metric runs --warmup unrecorded times first (the first enter may
# start a stopped container), then --runs recorded times; the enter metric
# runs before the shell one. --max-ms N turns the tool into a gate: exit 1
# when the SHELL median exceeds N ms. The < 300 ms target itself and the
# runtime decision (runc / crun) live in issue #22, not here.
#
# The backing script of `just box bench` (script/box/justfile.box forwards
# the arguments here verbatim); it also runs on its own:
#
#   ./script/box/bench.sh                          # dev box, 2 warmup + 10 runs
#   ./script/box/bench.sh --runs 3 --warmup 1      # quicker
#   ./script/box/bench.sh --max-ms 300             # gate: exit 1 above 300 ms
#   ./script/box/bench.sh --json                   # one JSON object instead
#   ./script/box/bench.sh --shell 'fish -c exit'   # time another shell
#   ./script/box/bench.sh --help                   # usage
#
# Output (stdout, machine-readable; diagnostics go to stderr via lib/log.sh):
#
#   enter: min=<ms> median=<ms> max=<ms> ms
#   shell: min=<ms> median=<ms> max=<ms> ms
#
# or, with --json, exactly one object:
#
#   {"box":"dev","runs":10,"warmup":2,"shell_cmd":"sh -c :","unit":"ms",
#    "enter":{"min":..,"median":..,"max":..},"shell":{...}}
#
# This script owns its option validation: the WHOLE command line is parsed
# before anything runs, so an unknown option anywhere in it is refused with
# `bench.sh: unknown option '<x>' (see --help)` on stderr, exit 2, and
# distrobox is never called; --help is served only after that. A run of the
# measured command that exits non-zero aborts the measurement (exit 1) - a
# failing enter has no latency worth reporting.
#
# Exit codes: 0 ok (and within --max-ms), 1 measurement failed or the shell
# median exceeds --max-ms, 2 usage error, 127 distrobox not on PATH.
#
# Exit-code-contract script: default guards are `set -uo pipefail` (no `-e`);
# failures are surfaced explicitly so a non-zero exit is always intentional.

# `source=` directives below resolve against lib/ (SCRIPTDIR/../../lib: the
# repo root is two levels up from script/box/). This file-wide directive
# must precede the first command (set) to take effect.
# shellcheck source-path=SCRIPTDIR/../../lib
set -uo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
LIB_DIR="${REPO_ROOT}/lib"

# shellcheck source=log.sh
source "${LIB_DIR}/log.sh"

# --- Defaults (overridden by the command line; see _parse_args) --------------
OPT_BOX="dev"
OPT_RUNS=10
OPT_WARMUP=2
OPT_MAX_MS=""          # empty = no gate
OPT_JSON=0
OPT_SHELL="sh -c :"
OPT_HELP=0

# --- Usage -------------------------------------------------------------------
_usage() {
    cat >&2 <<'EOF'
Usage: bench.sh [--box NAME] [--runs N] [--warmup N] [--max-ms N] [--json]
                [--shell CMD] [-h|--help]

Measure the enter latency of a worktool box with bash EPOCHREALTIME:

  enter   distrobox enter <box> -- true
  shell   distrobox enter <box> -- <shell>

Each metric runs --warmup unrecorded times, then --runs recorded times, and
prints `<metric>: min=<ms> median=<ms> max=<ms> ms` (one line each).

  --box NAME     Box to enter (default: dev).
  --runs N       Recorded runs per metric, N >= 1 (default: 10).
  --warmup N     Unrecorded runs per metric before measuring, N >= 0
                 (default: 2).
  --max-ms N     Exit 1 when the shell median exceeds N milliseconds
                 (default: no threshold; the target lives in issue #22).
  --json         Print one JSON object instead of the two text lines.
  --shell CMD    Command for the shell metric, word-split (default: sh -c :).
  -h, --help     Show this help and exit.
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

# Store the value $2 of the value-taking option $1 after validating it.
_set_opt() {
    case "$1" in
        --box)
            [[ -n "$2" ]] || { _usage_error "--box requires a non-empty name"; return 2; }
            OPT_BOX="$2" ;;
        --shell)
            [[ -n "$2" ]] || { _usage_error "--shell requires a non-empty command"; return 2; }
            OPT_SHELL="$2" ;;
        --runs)   _check_int_min "$1" "$2" 1 || return 2; OPT_RUNS=$(( 10#$2 )) ;;
        --warmup) _check_int_min "$1" "$2" 0 || return 2; OPT_WARMUP=$(( 10#$2 )) ;;
        --max-ms) _check_int_min "$1" "$2" 1 || return 2; OPT_MAX_MS=$(( 10#$2 )) ;;
    esac
}

# Parse the WHOLE command line into the OPT_* globals before anything runs,
# so an unknown option anywhere in it refuses the run as a whole. Returns 2
# on a usage error (message already printed).
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --box|--runs|--warmup|--max-ms|--shell)
                if [[ $# -lt 2 ]]; then
                    _usage_error "$1 requires an argument"
                    return 2
                fi
                _set_opt "$1" "$2" || return 2
                shift
                ;;
            --box=*|--runs=*|--warmup=*|--max-ms=*|--shell=*)
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

# Store the wall clock in microseconds in the variable named $1. No
# subshell: a $(...) fork would add its own latency to every sample.
# EPOCHREALTIME is "<seconds>.<6 digits>" (the radix follows the locale).
_now_us() {
    local -n _ref_now="$1"
    local _t="${EPOCHREALTIME/,/.}"
    _ref_now=$(( 10#${_t%.*} * 1000000 + 10#${_t#*.} ))
}

# Run the command $2.. once with stdin/stdout closed off (stderr passes
# through: it is diagnostics), store its wall time in microseconds in the
# variable named $1, and return the command's exit status.
_time_cmd() {
    local -n _ref_us="$1"
    shift
    local _t0 _t1 _rc
    _now_us _t0
    "$@" </dev/null >/dev/null
    _rc=$?
    _now_us _t1
    _ref_us=$(( _t1 - _t0 ))
    return "${_rc}"
}

# Time metric $1: OPT_WARMUP unrecorded runs, then OPT_RUNS recorded ones
# appended (microseconds) to the array named $2. The command is $3... The
# first run that exits non-zero aborts the metric (return 1).
_run_metric() {
    local _name="$1"
    local -n _ref_samples="$2"
    shift 2
    local _i _us _rc
    for (( _i = 0; _i < OPT_WARMUP + OPT_RUNS; _i++ )); do
        _time_cmd _us "$@"
        _rc=$?
        if (( _rc != 0 )); then
            log_error "${_name}: '$*' exited ${_rc} on run $(( _i + 1 )) - measurement aborted"
            return 1
        fi
        (( _i >= OPT_WARMUP )) && _ref_samples+=("${_us}")
    done
    log_info "${_name}: ${OPT_WARMUP} warmup + ${OPT_RUNS} run(s) of '$*' done"
    return 0
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

# Print $1 as a JSON string (backslash and double quote escaped).
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

# Print the one-object JSON report from the enter stats array named $1 and
# the shell stats array named $2 ("min median max" microseconds each).
_print_json() {
    local -n _ref_e="$1"
    local -n _ref_sh="$2"
    printf '{"box":%s,"runs":%s,"warmup":%s,"shell_cmd":%s,"unit":"ms","enter":%s,"shell":%s}\n' \
        "$(_json_str "${OPT_BOX}")" "${OPT_RUNS}" "${OPT_WARMUP}" \
        "$(_json_str "${OPT_SHELL}")" \
        "$(_json_metric "${_ref_e[@]}")" "$(_json_metric "${_ref_sh[@]}")"
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

# Measure both metrics and report. Runs only after the command line was
# fully validated.
_bench_exec() {
    if ! command -v distrobox >/dev/null 2>&1; then
        log_error "distrobox not found on PATH - cannot bench"
        return 127
    fi
    local -a _shell_argv _enter_us=() _shell_us=() _e_stats _s_stats
    read -r -a _shell_argv <<<"${OPT_SHELL}"

    _run_metric enter _enter_us distrobox enter "${OPT_BOX}" -- true || return 1
    _run_metric shell _shell_us distrobox enter "${OPT_BOX}" -- "${_shell_argv[@]}" || return 1

    _stats _enter_us _e_stats
    _stats _shell_us _s_stats
    if (( OPT_JSON )); then
        _print_json _e_stats _s_stats
    else
        _print_text enter "${_e_stats[@]}"
        _print_text shell "${_s_stats[@]}"
    fi
    _check_threshold "${_s_stats[1]}"
}

bench_run() {
    _parse_args "$@" || return 2
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
