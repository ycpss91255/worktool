#!/usr/bin/env bash
# lib/log.sh - minimal logging helpers for worktool.
#
# The first shared building block: every later lib/tool sources this for
# consistent, level-tagged diagnostics. All output goes to STDERR so stdout
# stays clean for machine-readable data (lists, paths, JSON) that callers
# may want to capture.
#
# Public API:
#   log_info  <message...>   -> "[INFO] <message>"  on stderr, returns 0
#   log_warn  <message...>   -> "[WARN] <message>"  on stderr, returns 0
#   log_error <message...>   -> "[ERROR] <message>" on stderr, returns 0
#
# This is a library: it defines functions and must be sourced, not executed.
# Sourcing has no side effects on stdout.

# --- Internal ----------------------------------------------------------------
# Emit "<tag> <message>" to stderr. Kept private (leading underscore) so the
# public surface stays exactly the three log_* helpers.
_log_emit() {
    local _tag="$1"
    shift
    printf '%s %s\n' "${_tag}" "$*" >&2
}

# --- Public helpers ----------------------------------------------------------
log_info() {
    _log_emit '[INFO]' "$@"
    return 0
}

log_warn() {
    _log_emit '[WARN]' "$@"
    return 0
}

log_error() {
    _log_emit '[ERROR]' "$@"
    return 0
}
