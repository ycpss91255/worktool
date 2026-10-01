#!/usr/bin/env bash
# assemble.sh - assemble the worktool shared "dev" box from its manifest.
#
# A thin, robust wrapper over `distrobox assemble create --file <manifest>`.
# It validates the manifest first (fail fast on a missing/invalid file) and
# then either prints the exact distrobox invocation (dry-run) or executes it.
# It never installs anything on the host and never needs root. Side effects:
# invoking distrobox, which manages the container itself, and - after a
# successful create, never in dry-run - symlinking the user config
# (~/.ssh, ~/.gitconfig, ~/.gnupg, ~/.config/gh, plus `link=` lines of the
# state file) into the box HOME (see "Box HOME" below; lib/link.sh, issue
# #199). A box whose HOME is the host HOME needs no links.
# Nothing is copied, no host file is modified, an existing entry is never
# overwritten.
#
# The backing script of `just box assemble` (script/box/justfile.box forwards
# the arguments here verbatim); it also runs on its own:
#
#   ./script/box/assemble.sh                       # assemble box/dev.ini
#   ./script/box/assemble.sh --file box/other.ini  # assemble a different manifest
#   ./script/box/assemble.sh --dry-run             # print the command, run nothing
#   ./script/box/assemble.sh --home /srv/dev-box   # the box's own HOME (issue #198)
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
# Box HOME (issue #198): distrobox fixes a box's HOME when it creates the
# box. `--home <path>` picks it (a stored user choice in the state file
# otherwise, then the default ~/<box>-box); it is logged as
# `[INFO] box home: <path> (default|user)`, handed to distrobox as
# DBX_CONTAINER_CUSTOM_HOME (distrobox-create's documented variable, so the
# dry-run command line stays the same), and recorded in
# the state file (lib/config.sh) after a successful run. An EXISTING box whose
# HOME differs is refused - exit 1, nothing changed, the remove-and-recreate
# commands printed - because only a new box can take a new HOME; worktool
# never removes a box by itself. When the container manager distrobox would
# use (DBX_CONTAINER_MANAGER, distrobox.conf, autodetect) is missing or
# fails, the run is refused the same way: it cannot tell whether the box
# exists. Dry-run never asks the container manager.
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
# shellcheck source=home.sh
source "${LIB_DIR}/home.sh"
# shellcheck source=link.sh
source "${LIB_DIR}/link.sh"

# Default manifest, relative to the repo root. It is resolved to a concrete
# path at run time (see _resolve_manifest): `box/dev.ini` when invoked from the
# repo root, or the absolute `${REPO_ROOT}/box/dev.ini` when invoked elsewhere.
DEFAULT_MANIFEST="box/dev.ini"

# --- Helpers -----------------------------------------------------------------
_usage() {
    config_fill >&2 <<'EOF'
Usage: assemble.sh [--file <manifest>] [--home <path>] [--dry-run]

Assemble the worktool dev box from its manifest with
`distrobox assemble create --file <manifest>`. After a successful create,
symlink the user config (~/.ssh ~/.gitconfig ~/.gnupg ~/.config/gh, plus
`link=<path>` lines of {state-file}) into the box HOME (see
--home); an existing entry is never overwritten.

  --file <manifest>  Box manifest to assemble (default: box/dev.ini).
  --home <path>      The box's own HOME, an absolute path (default: the
                     choice recorded in {state-file},
                     else ~/<box>-box, e.g. ~/dev-box). Fixed when the box
                     is created: an existing box with a different HOME is
                     refused (exit 1) - remove it and assemble again.
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
    OPT_MANIFEST="${DEFAULT_MANIFEST}" OPT_FILE_SET=0 OPT_HOME="" OPT_HOME_SET=0
    OPT_DRY_RUN=0 OPT_HELP=0
    [[ "${WORKTOOL_DRY_RUN:-}" == "1" ]] && OPT_DRY_RUN=1
    _parse_args "$@" || return 2
    if [[ "${OPT_HELP}" -eq 1 ]]; then
        _usage
        return 0
    fi
    _check_home_option || return 2

    # Resolve the manifest path ONCE and reuse that exact path everywhere:
    # validation, the dry-run output, and the real distrobox call. This keeps
    # the three consistent - validation can no longer pass against a resolved
    # path while distrobox is handed a different (possibly non-existent) one.
    local _resolved
    _resolved="$(_resolve_manifest "${OPT_MANIFEST}")"
    manifest_validate "${_resolved}" || return 1
    if home_manifest_sets_home "${_resolved}"; then
        log_error "manifest sets 'home=', which would override --home; remove it (the box HOME is chosen with --home): ${_resolved}"
        return 1
    fi
    _resolve_home "$(manifest_name "${_resolved}")" || return 1
    _assemble_exec "${_resolved}"
}

# Parse the whole command line into the OPT_* globals before anything
# runs, so an unknown option anywhere in it refuses the run as a whole.
# Returns 1 (the caller exits 2) on a usage error.
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file|--home)
                if [[ $# -lt 2 ]]; then
                    _usage_error "$1 requires a path argument"
                    return 1
                fi
                _set_opt "$1" "$2"
                shift
                ;;
            --file=*|--home=*) _set_opt "${1%%=*}" "${1#*=}" ;;
            --dry-run) OPT_DRY_RUN=1 ;;
            # Recorded, not served: `--help --bogus` is a usage error.
            -h|--help) OPT_HELP=1 ;;
            *)
                _usage_error "unknown option '$1'"
                return 1
                ;;
        esac
        shift
    done
}

_set_opt() {
    if [[ "$1" == --file ]]; then
        OPT_MANIFEST="$2" OPT_FILE_SET=1
    else
        OPT_HOME="$2" OPT_HOME_SET=1
    fi
}

# A --home that cannot be a box home is a usage error (exit 2 upstream).
_check_home_option() {
    local _problem
    [[ "${OPT_HOME_SET}" -eq 1 ]] || return 0
    if ! _problem="$(home_path_problem "${OPT_HOME}")"; then
        _usage_error "--home ${_problem}"
        return 1
    fi
    OPT_HOME="$(home_normalize "${OPT_HOME}")"
}

# Resolve the box home of box $1 into BOX_HOME / BOX_HOME_SRC: --home wins
# (user), then a stored user choice, then the default ~/<box>-box - the
# same order as `just box setup`. A corrupt stored home refuses the run.
_resolve_home() {
    local _problem
    BOX_NAME="$1"
    if ! _problem="$(home_config_check)"; then
        config_log error "" ": ${_problem}"
        return 1
    fi
    if [[ "${OPT_HOME_SET}" -eq 1 ]]; then
        BOX_HOME="${OPT_HOME}" BOX_HOME_SRC=user
    elif [[ "$(config_get home.source)" == user ]]; then
        BOX_HOME="$(home_normalize "$(config_get home)")"
        BOX_HOME_SRC=user
    else
        BOX_HOME="$(home_default "${BOX_NAME}")" BOX_HOME_SRC=default
    fi
    log_info "box home: ${BOX_HOME} (${BOX_HOME_SRC})"
}

# Refuse (return 1) when box BOX_NAME already exists with a HOME other than
# BOX_HOME: distrobox cannot change it, and removing the box is the user's
# call. Also refused when the container manager cannot say whether the box
# exists: guessing "no box" would record a HOME the box may not have.
# Nothing has been written or run at this point.
_check_existing_box() {
    local _existing _rc=0
    _existing="$(home_of_box "${BOX_NAME}")" || _rc=$?
    case "${_rc}" in
        0) ;;
        1) return 0 ;;
        2)
            log_error "box '${BOX_NAME}' already exists, but its HOME cannot be read from the container manager; nothing was changed"
            return 1
            ;;
        *)
            log_error "cannot tell whether box '${BOX_NAME}' already exists: ${_existing}; nothing was changed"
            return 1
            ;;
    esac
    [[ "$(home_normalize "${_existing}")" != "${BOX_HOME}" ]] || return 0
    _refuse_home_change "${_existing}"
    return 1
}

# The rebuild hints repeat --file when the run was given one, as an
# absolute path: `just box assemble` runs from the repo root, not from
# where the user stood.
_refuse_home_change() {
    local _old="$1" _base="just box assemble" _redo _keep
    [[ "${OPT_FILE_SET}" -eq 0 ]] \
        || _base+=" --file $(printf '%q' "$(_absolute_path "${RESOLVED}")")"
    _redo="${_base}"
    [[ "${BOX_HOME_SRC}" == user ]] && _redo+=" --home $(printf '%q' "${BOX_HOME}")"
    _keep="${_base} --home $(printf '%q' "${_old}")"
    log_error "box '${BOX_NAME}' already exists with HOME ${_old}; distrobox sets a box's HOME only when the box is created, so it cannot become ${BOX_HOME}. Nothing was changed."
    log_error "to use ${BOX_HOME}, remove the box and recreate it (the files under ${_old} stay on disk):"
    log_error "  distrobox rm ${BOX_NAME}"
    log_error "  ${_redo}"
    log_error "or keep the current HOME: ${_keep}"
}

# Existing file $1 as an absolute path (its directory resolved).
_absolute_path() {
    printf '%s/%s\n' "$(cd -P -- "$(dirname -- "$1")" && pwd)" "$(basename -- "$1")"
}

# Emit (dry-run) or execute the distrobox command for the resolved
# manifest $1, then record the box home.
_assemble_exec() {
    local _resolved="$1"
    local _cmd=(distrobox assemble create --file "${_resolved}")
    RESOLVED="${_resolved}"

    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
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

    _check_existing_box || return 1
    log_info "assembling box from ${_resolved}"
    local _rc=0
    DBX_CONTAINER_CUSTOM_HOME="${BOX_HOME}" "${_cmd[@]}" || _rc=$?
    [[ "${_rc}" -eq 0 ]] || return "${_rc}"
    if ! home_record "${BOX_HOME}" "${BOX_HOME_SRC}"; then
        config_log error "failed to record the box home in "
        return 1
    fi
    config_log info "recorded box home in "
    _assemble_link
}

# Link the user config into the box HOME (issue #199, lib/link.sh): only
# after a successful create, never in dry-run. The box HOME is BOX_HOME,
# the one _resolve_home picked and home_record just recorded (issue #198) -
# the same path distrobox was given. A box whose HOME is the host HOME
# (`--home ~`) already sees the user config: nothing to link.
_assemble_link() {
    if [[ "${BOX_HOME}" == "$(home_normalize "${HOME}")" ]]; then
        log_info "link: box ${BOX_NAME} shares the host HOME - user config already in place"
        return 0
    fi
    log_info "linking user config into the box HOME ${BOX_HOME}"
    link_apply "${BOX_HOME}"
}

# Guard: only run when executed directly, not when sourced (keeps the file
# importable by tests).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    assemble_run "$@"
fi
