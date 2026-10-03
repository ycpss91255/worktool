#!/usr/bin/env bash
# lib/guard.sh - the primitives that stop a FAILURE from reading as a PASS.
#
# Written for script/verify/realbox.sh, which replaced three shell blocks
# that used to live inside doc/acceptance.md. The bug those blocks shared was
# never a wrong check; it was that a broken check answered like a passing one:
#
#   out=$(cmd) ; use "$out"          a dead cmd leaves "" and "" compares equal
#   cmd | parser                     a dead first stage is an empty stream,
#                                    which parses as "nothing is there"
#   n=$(grep -c ... file)            grep's 1 (no match) and its 2 (cannot
#                                    read the file) both look like a number
#
# Every helper here answers with a status that keeps those cases apart, or
# refuses to answer at all. Nothing in this file prints a result line; a
# reason goes to stderr as `[FAIL] ...` or `[UNAVAILABLE] ...`; the status
# carries the verdict.
#
# Public API:
#   guard_fail <message...>          -> `[FAIL] <message>` on stderr, returns 1
#   guard_timed <secs> <cmd...>      -> run <cmd> under a timeout
#   guard_require <cmd...>           -> 0 tools present / 3 unavailable
#   guard_box_exists <name>          -> 0 exists / 1 absent / 2 CANNOT TELL
#   guard_sha256 <file>              -> the file's sha256, or status 1
#   guard_path_type <path>           -> regular | symlink | absent | other
#   guard_field <dir> <key>          -> value of <key>= in <dir>/manifest
#   guard_count_lines <file> <re>    -> how many lines of <file> match <re>
#
# This is a library: it defines functions and must be sourced, not executed.
# Sourcing has no side effects on stdout.

# --- Reporting ---------------------------------------------------------------
guard_fail() {
    printf '[FAIL] %s\n' "$*" >&2
    return 1
}

# --- Running external tools --------------------------------------------------

# Run "$@" under a timeout of $1 seconds, so a hung tool becomes a failure
# (124) rather than a stall. -k 10 reaps one that ignores SIGTERM.
guard_timed() {
    local _secs="$1"
    shift
    timeout -k 10 "${_secs}" "$@"
}

# Every tool a caller needs must be on PATH BEFORE the caller does anything.
# A missing tool is reported as unavailable (3) - never a check that
# quietly did not run.
guard_require() {
    local _c _missing=0
    for _c in "$@"; do
        command -v -- "${_c}" >/dev/null 2>&1 \
            || { printf '[UNAVAILABLE] %s: missing command: %s\n' "${0##*/}" "${_c}" >&2; _missing=3; }
    done
    return "${_missing}"
}

# --- distrobox ---------------------------------------------------------------

# 0 = a box named $1 exists, 1 = it does not, 2 = cannot tell. Never guesses.
#
# THE GUARD: `distrobox list` is collected into a variable so its own exit
# status is visible. Piped straight into awk, a broken list is an empty stream
# and parses as "no such box" - the single answer that would let a caller
# create a box over someone else's, or delete one it never made. awk's own
# failure (>= 2) is kept apart from awk's "not found" (1) for the same reason.
guard_box_exists() {
    local _want="$1" _secs="${2:-180}" _out _st
    _out="$(guard_timed "${_secs}" distrobox list 2>/dev/null)" || return 2
    printf '%s\n' "${_out}" | awk -F'|' -v want="${_want}" '
        NR > 1 { n = $2; gsub(/^[ \t]+|[ \t]+$/, "", n); if (n == want) f = 1 }
        END { exit(f ? 0 : 1) }'
    _st=$?
    [[ "${_st}" -eq 0 || "${_st}" -eq 1 ]] || return 2
    return "${_st}"
}

# --- Files -------------------------------------------------------------------

# `sha256sum | cut`, collected FIRST so sha256sum's status is not hidden behind
# cut's, and validated as 64 hex digits so a mangled read cannot be stored as a
# plausible-looking checksum.
guard_sha256() {
    local _out
    _out="$(sha256sum -- "$1" | cut -d' ' -f1)" || return 1
    [[ "${_out}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "${_out}"
}

# regular | symlink | absent | other. -L first: a dangling link is still a link.
guard_path_type() {
    if [[ -L "$1" ]]; then
        printf 'symlink\n'
    elif [[ ! -e "$1" ]]; then
        printf 'absent\n'
    elif [[ -f "$1" ]]; then
        printf 'regular\n'
    else
        printf 'other\n'
    fi
}

# Read key $2 out of the manifest in directory $1. `grep -m1` stops by itself,
# so pipefail never sees the SIGPIPE a `| head -1` would cause. A MISSING key
# returns 1, which is told apart from a key whose value is legitimately empty.
guard_field() {
    local _line
    _line="$(grep -m1 -E "^$2=" -- "$1/manifest")" || return 1
    printf '%s\n' "${_line#*=}"
}

# How many lines of file $1 match extended regex $2.
#
# THE GUARD: `grep -c` exits 1 for "zero matches" (a real answer) and >= 2 when
# it cannot read the file at all. Only the first may become a count; the second
# returns 1 here, or an unreadable file would answer "0" - a zero that means
# something entirely different from "I looked and found none".
guard_count_lines() {
    local _out _rc
    _out="$(grep -cE "$2" -- "$1")"
    _rc=$?
    [[ "${_rc}" -le 1 ]] || return 1
    [[ "${_out}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${_out}"
}
