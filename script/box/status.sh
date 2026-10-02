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
# The user-config link states and the recorded box HOME follow the entry
# report (issues #199 and #198).
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
# shellcheck source=home.sh
source "${LIB_DIR}/home.sh"
# shellcheck source=link.sh
source "${LIB_DIR}/link.sh"

# --- Usage -------------------------------------------------------------------
_usage() {
    config_fill >&2 <<'EOF'
Usage: status.sh

Show the auto-enter decisions in force (from {state-file},
written by `just box setup`), the source of each (default | user), whether
the worktool managed block is present in the ghostty config and in
distrobox.conf (the block that keeps a host tmux pane's TMUX out of the
box), whether the wrapper and distrobox the ghostty block names can still be run,
the user-config link states and the recorded box HOME.
Read-only. A corrupt state file is refused: `[ERROR] <file>: invalid value
...` on stderr, exit 1.

  -h, --help   Show this help and exit.
EOF
}

_usage_error() {
    printf 'status.sh: %s (see --help)\n' "$1" >&2
}

# --- Report ------------------------------------------------------------------

# Print `<key>: <value> (<source>)` for key $1 from the state file: the
# stored value with its stored source, or the default when the key is
# absent.
_report_key() {
    local _key="$1" _value _source
    _value="$(config_get "${_key}")"
    _source="$(config_get "${_key}.source")"
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
    if _problem="$(enter_config_check)" && _problem="$(home_config_check)"; then
        return 0
    fi
    config_log error "" ": ${_problem}"
    return 1
}

_report() {
    local _key
    _config_check || return 1
    if config_exists; then
        config_say "config: "
    else
        config_say "config: " " (not found - defaults shown; run: just box setup)"
    fi
    while IFS= read -r _key; do
        _report_key "${_key}"
    done < <(enter_keys)
    _report_ghostty
    _report_block distrobox.conf "$(enter_distrobox_conf)"
    _report_wrapper
    _report_distrobox
    _report_links
    _report_home
}

# Report the selected file and any existing companion, so a block that
# has not yet migrated and malformed markers remain visible.
_report_ghostty() {
    local _target _other
    _target="$(enter_ghostty_target)"
    _other="$(enter_config_dir)/ghostty/config"
    [[ "${_target}" != "${_other}" ]] || _other+=".ghostty"
    _report_block ghostty "${_target}"
    if [[ -e "${_other}" ]]; then
        _report_block ghostty "${_other}"
    fi
}

# `link: <box home>/<path> -> $HOME/<path> (<state>)` per user-config entry
# (issue #199), each state as lib/link.sh reads it. The box HOME is the one
# `just box assemble` recorded in the state file (issue #198, the same
# value _report_home prints); none recorded, or the host HOME itself: one
# line says so.
_report_links() {
    local _box_home _rel _state
    _box_home="$(config_get home)"
    if [[ -z "${_box_home}" ]]; then
        printf 'link: box HOME not recorded - user config not linked yet (run: just box assemble)\n'
        return 0
    fi
    _box_home="$(home_normalize "${_box_home}")"
    if [[ "${_box_home}" == "$(home_normalize "${HOME}")" ]]; then
        printf 'link: the box HOME is the host HOME - user config already in place\n'
        return 0
    fi
    while IFS= read -r _rel; do
        case "$(link_state "${_rel}" "${_box_home}")" in
            linked)         _state="linked" ;;
            missing-source) _state="missing source" ;;
            blocked)        _state="blocked by existing file" ;;
            *)              _state="not linked yet; run: just box assemble" ;;
        esac
        printf 'link: %s/%s -> %s/%s (%s)\n' "${_box_home}" "${_rel}" "${HOME}" "${_rel}" "${_state}"
    done < <(link_entries)
}

# `home: <path> (<source>)` - the box HOME `just box assemble` recorded in
# the state file (issue #198), or that none is recorded yet.
_report_home() {
    local _home
    _home="$(config_get home)"
    if [[ -z "${_home}" ]]; then
        printf 'home: not recorded (run: just box assemble)\n'
        return 0
    fi
    printf 'home: %s (%s)\n' "${_home}" "$(config_get home.source)"
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
    local _recorded="" _file _target
    _target="$(enter_ghostty_target)"
    for _file in "${_target}" "$(enter_config_dir)/ghostty/config" "$(enter_config_dir)/ghostty/config.ghostty"; do
        _recorded="$(enter_body_distrobox "$(enter_block_body "${_file}")")"
        [[ -z "${_recorded}" ]] || break
    done
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

# Read every managed profile, including an unmigrated companion file.
_report_wrapper() {
    local _file _path _state
    for _file in "$(enter_ghostty_target)" "$(enter_config_dir)/ghostty/config" "$(enter_config_dir)/ghostty/config.ghostty"; do
        _path="$(enter_body_wrapper "$(enter_block_body "${_file}")")"
        [[ -n "${_path}" ]] || continue
        _state="runnable"
        if [[ ! -f "${_path}" || ! -x "${_path}" ]]; then
            _state="NOT RUNNABLE - moved or removed; re-run: just box setup"
        fi
        printf 'wrapper: %s (recorded in a managed block: %s)\n' "${_path}" "${_state}"
        return 0
    done
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
