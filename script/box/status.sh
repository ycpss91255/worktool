#!/usr/bin/env bash
# status.sh - show the auto-enter decisions in force and their sources (M3, #21).
#
# The read side of `just box setup`: prints the ONE state file's decisions
# (auto-enter, terminal, box), each with its source (default | user),
# whether the worktool managed block is present in the ghostty config, and
# - since issue #175 - whether the distrobox that block names can still be
# run, and - since issue #179 - whether distrobox.conf holds the block that
# keeps a host tmux pane's TMUX out of the box. Read-only: it never writes. Since issue #179 there is no tmux line:
# worktool does not manage tmux, and never looks at ~/.tmux.conf.
#
# The backing script of `just box status` (script/box/justfile.box forwards
# the arguments here verbatim); it also runs on its own:
#
#   ./script/box/status.sh          # the report
#   ./script/box/status.sh --help   # usage
#
# The report goes to STDOUT (plain `<key>: <value> (<source>)` lines, no log
# tags, so it can be grepped); nothing goes to stderr on success. Without a
# state file the first line says so and the defaults are shown, so the
# report is never empty. A corrupt state file (a stored value or source that
# is not an allowed value, whatever the source says) is refused before any
# report line: `[ERROR] <file>: invalid value ...` on stderr, exit 1 - the
# same check and message as setup.sh. Every path derives from
# HOME / XDG_CONFIG_HOME (lib/enter.sh).
#
# This script owns its option validation: an unknown option is refused with
# `status.sh: unknown option '<x>' (see --help)` on stderr, exit 2.
#
# Guards: `set -euo pipefail` (doc/adr/0001-scripts-use-errexit.md): an
# unhandled failure stops the script at once. A non-zero status the script
# EXPECTS is handled explicitly (`if ! cmd`, `cmd || _rc=$?`), never
# swallowed with `|| true`, so every exit code documented here stays the
# script's own.

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

# --- Usage -------------------------------------------------------------------
_usage() {
    cat >&2 <<'EOF'
Usage: status.sh

Show the auto-enter decisions in force (from $XDG_CONFIG_HOME/worktool/config,
written by `just box setup`), the source of each (default | user), whether
the worktool managed block is present in the ghostty config and in
distrobox.conf (the block that keeps a host tmux pane's TMUX out of the
box), and whether the distrobox the ghostty block names can still be run.
Read-only. A corrupt state file is refused: `[ERROR] <file>: invalid value
...` on stderr, exit 1.

  -h, --help   Show this help and exit.
EOF
}

_usage_error() {
    printf 'status.sh: %s (see --help)\n' "$1" >&2
}

# --- Report ------------------------------------------------------------------

# Print `<key>: <value> (<source>)` for key $1 from state file $2: the stored
# value with its stored source, or the default when the key is absent.
_report_key() {
    local _key="$1" _config="$2" _value _source
    _value="$(enter_config_get "${_config}" "${_key}")"
    _source="$(enter_config_get "${_config}" "${_key}.source")"
    if [[ -z "${_value}" ]]; then
        _value="$(enter_default "${_key}")"
        _source="default"
    fi
    printf '%s: %s (%s)\n' "${_key}" "${_value}" "${_source:-default}"
}

# Print `<label>: <file> (managed block: present|absent|MALFORMED - ...)`.
# Malformed markers are what setup.sh refuses to rewrite, so the report
# says so rather than calling the block present.
_report_block() {
    local _label="$1" _file="$2" _state="absent" _problem
    if ! _problem="$(enter_block_check "${_file}")"; then
        _state="MALFORMED - ${_problem}; fix or remove the markers, then re-run: just box setup"
    elif enter_block_present "${_file}"; then
        _state="present"
    fi
    printf '%s: %s (managed block: %s)\n' "${_label}" "${_file}" "${_state}"
}

# Refuse a corrupt state file before any report line (same check and
# message as setup.sh): exit 1 upstream.
_config_check() {
    local _problem
    _problem="$(enter_config_check "$1")" && return 0
    log_error "$1: ${_problem}"
    return 1
}

_report() {
    local _config _key
    _config="$(enter_config_path)"
    _config_check "${_config}" || return 1
    if [[ -f "${_config}" ]]; then
        printf 'config: %s\n' "${_config}"
    else
        printf 'config: %s (not found - defaults shown; run: just box setup)\n' "${_config}"
    fi
    while IFS= read -r _key; do
        _report_key "${_key}" "${_config}"
    done < <(enter_keys)
    _report_block ghostty "$(enter_ghostty_config)"
    _report_block distrobox.conf "$(enter_distrobox_conf)"
    _report_distrobox
}

# `distrobox: <path> (<state>)` - the readable answer to "will the managed
# command actually run?" (issue #175).
#
# The managed command names an ABSOLUTE distrobox path, so a distrobox
# that is later moved, upgraded away or removed turns a desktop-launched
# terminal into a window that flashes `not found` and closes. This line
# says it where the user can read it. When no managed block records one,
# it reports what the next `just box setup` would resolve instead, so the
# line is never absent.
_report_distrobox() {
    local _recorded
    _recorded="$(enter_body_distrobox "$(enter_block_body "$(enter_ghostty_config)")")"
    if [[ -n "${_recorded}" ]]; then
        _report_recorded_distrobox "${_recorded}"
        return 0
    fi
    if _recorded="$(enter_distrobox_program)"; then
        printf 'distrobox: %s (on PATH; no managed block records one)\n' "${_recorded}"
    else
        printf 'distrobox: not found on PATH (install distrobox, then re-run: just box setup)\n'
    fi
}

# The three states a recorded distrobox $1 can be in. A bare name is the
# fallback an older setup (or a setup run with no distrobox on PATH) left
# behind: it is not an error yet, but it is the shape issue #175 was about.
_report_recorded_distrobox() {
    if [[ "$1" != /* ]]; then
        printf 'distrobox: %s (recorded in a managed block: a bare name, not an absolute path - a terminal launched from the desktop may not find it; re-run: just box setup)\n' "$1"
    elif [[ -x "$1" ]]; then
        printf 'distrobox: %s (recorded in a managed block: runnable)\n' "$1"
    else
        printf 'distrobox: %s (recorded in a managed block: NOT RUNNABLE - moved or removed; re-run: just box setup)\n' "$1"
    fi
}

# --- Main --------------------------------------------------------------------
status_run() {
    local _help=0
    # The whole command line is parsed before anything runs.
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
    _report
}

# Guard: only run when executed directly, not when sourced (keeps the file
# importable by tests).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    status_run "$@"
fi
