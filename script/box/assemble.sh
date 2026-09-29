#!/usr/bin/env bash
# assemble.sh - assemble the worktool shared "dev" box from its manifest.
#
# A thin, robust wrapper over `distrobox assemble create --file <manifest>`.
# It validates the manifest first (fail fast on a missing/invalid file) and
# then either prints the exact distrobox invocation (dry-run) or executes it.
# It never installs anything on the host and never needs root - the only
# side effect is invoking distrobox, which manages the container itself.
#
# The backing script of `just box assemble` (script/box/justfile.box forwards
# the arguments here verbatim); it also runs on its own:
#
#   ./script/box/assemble.sh                       # assemble box/dev.ini
#   ./script/box/assemble.sh --file box/other.ini  # assemble a different manifest
#   ./script/box/assemble.sh --dry-run             # print the command, run nothing
#   WORKTOOL_DRY_RUN=1 ./script/box/assemble.sh    # same, via env var
#   ./script/box/assemble.sh --help                # usage
#
# This script owns its option validation: an unknown option is refused with
# `assemble.sh: unknown option '<x>' (see --help)` on stderr, exit 2, before
# anything runs, so the justfile in front of it never has to.
#
# Dry-run prints the command to STDOUT (clean, machine-readable); all
# diagnostics go to STDERR via lib/log.sh. This is what the unit tests assert.
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
# shellcheck source=manifest.sh
source "${LIB_DIR}/manifest.sh"

# Default manifest, relative to the repo root. It is resolved to a concrete
# path at run time (see _resolve_manifest): `box/dev.ini` when invoked from the
# repo root, or the absolute `${REPO_ROOT}/box/dev.ini` when invoked elsewhere.
DEFAULT_MANIFEST="box/dev.ini"

# --- Helpers -----------------------------------------------------------------
_usage() {
    cat >&2 <<'EOF'
Usage: assemble.sh [--file <manifest>] [--dry-run]

Assemble the worktool dev box from its manifest with
`distrobox assemble create --file <manifest>`.

  --file <manifest>  Box manifest to assemble (default: box/dev.ini).
  --dry-run          Print the distrobox command without executing it
                     (also enabled by WORKTOOL_DRY_RUN=1).
  -h, --help         Show this help and exit.
EOF
}

# Refuse the command line: one line on stderr (the caller returns 2; nothing
# has run yet).
_usage_error() {
    printf 'assemble.sh: %s (see --help)\n' "$1" >&2
}

# Resolve a manifest argument to an existing path for validation, while the
# caller keeps the original (possibly relative) string for the emitted
# command. Absolute paths pass through; a relative path is tried against the
# current directory first, then the repo root; an unresolved path is returned
# as-is so validation reports a clear "not found".
_resolve_manifest() {
    local _arg="$1"
    if [[ "${_arg}" == /* ]]; then
        printf '%s\n' "${_arg}"
    elif [[ -f "${_arg}" ]]; then
        printf '%s\n' "${_arg}"
    elif [[ -f "${REPO_ROOT}/${_arg}" ]]; then
        printf '%s\n' "${REPO_ROOT}/${_arg}"
    else
        printf '%s\n' "${_arg}"
    fi
}

# --- Main --------------------------------------------------------------------
assemble_run() {
    local _manifest_arg="${DEFAULT_MANIFEST}"
    local _dry_run=0 _help=0
    [[ "${WORKTOOL_DRY_RUN:-}" == "1" ]] && _dry_run=1

    # The whole command line is parsed before anything runs, so an unknown
    # option anywhere in it refuses the run as a whole.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)
                shift
                if [[ $# -eq 0 ]]; then
                    _usage_error "--file requires a path argument"
                    return 2
                fi
                _manifest_arg="$1"
                ;;
            --file=*) _manifest_arg="${1#*=}" ;;
            --dry-run) _dry_run=1 ;;
            # Recorded, not served: `--help --bogus` is a usage error.
            -h|--help) _help=1 ;;
            *)
                _usage_error "unknown option '$1'"
                return 2
                ;;
        esac
        shift
    done
    if [[ "${_help}" -eq 1 ]]; then
        _usage
        return 0
    fi

    # Resolve the manifest path ONCE and reuse that exact path everywhere:
    # validation, the dry-run output, and the real distrobox call. This keeps
    # the three consistent - validation can no longer pass against a resolved
    # path while distrobox is handed a different (possibly non-existent) one.
    local _resolved
    _resolved="$(_resolve_manifest "${_manifest_arg}")"
    manifest_validate "${_resolved}" || return 1
    _assemble_exec "${_resolved}" "${_dry_run}"
}

# Emit (dry-run, $2 = 1) or execute the distrobox command for the resolved
# manifest $1.
_assemble_exec() {
    local _resolved="$1" _dry_run="$2"
    local _cmd=(distrobox assemble create --file "${_resolved}")

    if [[ "${_dry_run}" -eq 1 ]]; then
        # Print with per-argument shell escaping so the line is faithfully
        # re-runnable: a path containing spaces, `;` or `$()` is represented
        # as a single safe argument, not split or interpreted on replay.
        local _quoted
        printf -v _quoted ' %q' "${_cmd[@]}"
        printf '%s\n' "${_quoted# }"
        return 0
    fi

    if ! command -v distrobox >/dev/null 2>&1; then
        log_error "distrobox not found on PATH - cannot assemble (try --dry-run)"
        return 127
    fi

    log_info "assembling box from ${_resolved}"
    "${_cmd[@]}"
}

# Guard: only run when executed directly, not when sourced (keeps the file
# importable by tests).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    assemble_run "$@"
fi
