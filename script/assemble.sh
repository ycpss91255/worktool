#!/usr/bin/env bash
# assemble.sh - assemble the worktool shared "dev" box from its manifest.
#
# A thin, robust wrapper over `distrobox assemble create --file <manifest>`.
# It validates the manifest first (fail fast on a missing/invalid file) and
# then either prints the exact distrobox invocation (dry-run) or executes it.
# It never installs anything on the host and never needs root - the only
# side effect is invoking distrobox, which manages the container itself.
#
# Usage:
#   ./script/assemble.sh                       # assemble box/dev.ini
#   ./script/assemble.sh --file box/other.ini  # assemble a different manifest
#   ./script/assemble.sh --dry-run             # print the command, run nothing
#   WORKTOOL_DRY_RUN=1 ./script/assemble.sh    # same, via env var
#
# Dry-run prints the command to STDOUT (clean, machine-readable); all
# diagnostics go to STDERR via lib/log.sh. This is what the unit tests assert.
#
# Exit-code-contract script: default guards are `set -uo pipefail` (no `-e`);
# failures are surfaced explicitly so a non-zero exit is always intentional.

# `source=` directives below resolve against lib/ (SCRIPTDIR/../lib). This
# file-wide directive must precede the first command (set) to take effect.
# shellcheck source-path=SCRIPTDIR/../lib
set -uo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
LIB_DIR="${REPO_ROOT}/lib"

# shellcheck source=log.sh
source "${LIB_DIR}/log.sh"
# shellcheck source=manifest.sh
source "${LIB_DIR}/manifest.sh"

# Default manifest, expressed relative so the emitted command stays stable
# and portable (e.g. `distrobox assemble create --file box/dev.ini`).
DEFAULT_MANIFEST="box/dev.ini"

# --- Helpers -----------------------------------------------------------------
_usage() {
    cat >&2 <<'EOF'
Usage: assemble.sh [--file <manifest>] [--dry-run]

  --file <manifest>  Box manifest to assemble (default: box/dev.ini).
  --dry-run          Print the distrobox command without executing it
                     (also enabled by WORKTOOL_DRY_RUN=1).
  -h, --help         Show this help.
EOF
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
    local _dry_run=0
    [[ "${WORKTOOL_DRY_RUN:-}" == "1" ]] && _dry_run=1

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)
                shift
                if [[ $# -eq 0 ]]; then
                    log_error "--file requires a path argument"
                    return 2
                fi
                _manifest_arg="$1"
                ;;
            --file=*) _manifest_arg="${1#*=}" ;;
            --dry-run) _dry_run=1 ;;
            -h|--help) _usage; return 0 ;;
            *)
                log_error "unknown argument: $1"
                _usage
                return 2
                ;;
        esac
        shift
    done

    local _resolved
    _resolved="$(_resolve_manifest "${_manifest_arg}")"
    manifest_validate "${_resolved}" || return 1

    # Keep the argument as-given so the command is stable and relative.
    local _cmd=(distrobox assemble create --file "${_manifest_arg}")

    if [[ "${_dry_run}" -eq 1 ]]; then
        printf '%s\n' "${_cmd[*]}"
        return 0
    fi

    if ! command -v distrobox >/dev/null 2>&1; then
        log_error "distrobox not found on PATH - cannot assemble (try --dry-run)"
        return 127
    fi

    log_info "assembling box from ${_manifest_arg}"
    "${_cmd[@]}"
}

# Guard: only run when executed directly, not when sourced (keeps the file
# importable by tests).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    assemble_run "$@"
fi
