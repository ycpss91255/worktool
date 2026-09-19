#!/usr/bin/env bash
# setup.sh - choose how a new terminal enters the worktool dev box (M3, #21).
#
# The auto-enter mechanism is NOT pinned: the user picks it here, the
# default is "enter directly", and every decision is logged and can be read
# back with `just box status`. Only files under HOME / XDG_CONFIG_HOME are
# touched; nothing is installed and no host shell rc is edited (a terminal
# profile is the cleanest boundary: ssh, cron and non-interactive shells
# stay untouched).
#
# The backing script of `just box setup` (script/box/justfile.box forwards
# the arguments here verbatim); it also runs on its own:
#
#   ./script/box/setup.sh                       # defaults: yes / detected / inside / dev
#   ./script/box/setup.sh --tmux host           # tmux on the host, panes enter the box
#   ./script/box/setup.sh --auto-enter no       # restore the host shell
#   ./script/box/setup.sh --dry-run             # log everything, write nothing
#   ./script/box/setup.sh --help                # usage
#
# Decisions (option (user) > stored user choice > default; each logged as
# `[INFO] <key>: <value> (<source>)`):
#   auto-enter  yes|no        default yes
#   terminal    ghostty|none  default ghostty when a ghostty config dir exists
#   tmux        inside|host   default inside
#   box         <name>        default dev
#
# State file: $XDG_CONFIG_HOME/worktool/config (~/.config/worktool/config),
# `<key>=<value>` plus `<key>.source=default|user` per key. A user choice
# persists across runs until overridden; default keys are recomputed.
#
# Managed blocks (begin/end marker lines, at most one per file, replaced in
# place, user content preserved):
#   auto-enter yes, terminal ghostty, tmux inside:
#     <config dir>/ghostty/config  command = distrobox enter <box> -- tmux new -A -s main
#   auto-enter yes, terminal ghostty, tmux host:
#     <config dir>/ghostty/config  command = tmux new -A -s main
#     ~/.tmux.conf                 set -g default-command "distrobox enter <box>"
#   auto-enter no: both blocks removed, each removal reported.
#
# This script owns its option validation: an unknown option or an invalid
# value is refused with `setup.sh: ... (see --help)` on stderr, exit 2,
# before anything runs. All diagnostics go to STDERR via lib/log.sh.
#
# Exit-code-contract script: default guards are `set -uo pipefail` (no `-e`);
# failures are surfaced explicitly so a non-zero exit is always intentional.

# shellcheck source-path=SCRIPTDIR/../../lib
set -uo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
LIB_DIR="${REPO_ROOT}/lib"

# shellcheck source=log.sh
source "${LIB_DIR}/log.sh"
# shellcheck source=enter.sh
source "${LIB_DIR}/enter.sh"

# --- Option state (set by _parse_args) ---------------------------------------
OPT_AUTO_ENTER=""
OPT_TERMINAL=""
OPT_TMUX=""
OPT_BOX=""
OPT_DRY_RUN=0
OPT_HELP=0

# --- Resolved decisions (set by _resolve_all) --------------------------------
CONFIG=""
AUTO_ENTER="" TERMINAL="" TMUX="" BOX=""
AUTO_ENTER_SRC="" TERMINAL_SRC="" TMUX_SRC="" BOX_SRC=""

# --- Usage -------------------------------------------------------------------
_usage() {
    cat >&2 <<'EOF'
Usage: setup.sh [--auto-enter yes|no] [--terminal ghostty|none]
                [--tmux inside|host] [--box <name>] [--dry-run]

Choose how a new terminal enters the worktool dev box, store the choice in
$XDG_CONFIG_HOME/worktool/config and write the terminal profile for it.
Every decision is logged as `[INFO] <key>: <value> (default|user)`; read it
back any time with `just box status`.

  --auto-enter yes|no       Enter the box automatically (default: yes).
                            `no` removes the managed blocks and restores the
                            host shell, reporting what was removed.
  --terminal ghostty|none   Terminal profile to manage (default: ghostty when
                            $XDG_CONFIG_HOME/ghostty or ~/.config/ghostty
                            exists, else none).
  --tmux inside|host        Where tmux runs (default: inside): inside the box
                            (ghostty: distrobox enter <box> -- tmux new -A -s
                            main) or on the host (ghostty: tmux new -A -s
                            main; ~/.tmux.conf: set -g default-command
                            "distrobox enter <box>").
  --box <name>              Box to enter (default: dev).
  --dry-run                 Log every decision and file action; write nothing.
  -h, --help                Show this help and exit.

Files (all under HOME / XDG_CONFIG_HOME; a managed block is delimited by
`# BEGIN worktool managed block ...` / `# END worktool managed block`):
  $XDG_CONFIG_HOME/worktool/config   the state file (key=value + key.source)
  $XDG_CONFIG_HOME/ghostty/config    managed block: command = ...
  ~/.tmux.conf                       managed block (tmux host only)
EOF
}

# Refuse the command line: one line on stderr (the caller returns 2; nothing
# has run yet).
_usage_error() {
    printf 'setup.sh: %s (see --help)\n' "$1" >&2
}

# --- Argument parsing --------------------------------------------------------

# Store option $1 (--auto-enter / --terminal / --tmux / --box) = value $2
# after validating the value. Returns 2 on an invalid value.
_set_opt() {
    local _key="${1#--}"
    if ! enter_value_ok "${_key}" "$2"; then
        _usage_error "invalid value '$2' for $1 (expected $(_expected "${_key}"))"
        return 2
    fi
    case "${_key}" in
        auto-enter) OPT_AUTO_ENTER="$2" ;;
        terminal)   OPT_TERMINAL="$2" ;;
        tmux)       OPT_TMUX="$2" ;;
        box)        OPT_BOX="$2" ;;
    esac
}

# Human form of the allowed values of key $1, for error messages.
_expected() {
    if [[ "$1" == "box" ]]; then
        printf 'a container name: [A-Za-z0-9][A-Za-z0-9_.-]*'
    else
        enter_choices "$1"
    fi
}

# Parse the WHOLE command line before anything runs, so an unknown option
# anywhere in it refuses the run as a whole. Returns 2 on a usage error.
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto-enter|--terminal|--tmux|--box)
                if [[ $# -lt 2 ]]; then
                    _usage_error "$1 requires a value"
                    return 2
                fi
                _set_opt "$1" "$2" || return 2
                shift
                ;;
            --auto-enter=*|--terminal=*|--tmux=*|--box=*)
                _set_opt "${1%%=*}" "${1#*=}" || return 2
                ;;
            --dry-run) OPT_DRY_RUN=1 ;;
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

# --- Decision resolution -----------------------------------------------------

# Print `<value> <source>` for key $1 given its option value $2: the option
# wins (user), then a stored choice whose source is user, then the default.
# A stored value that is not a valid choice is refused (exit 1 upstream):
# the state file is user-editable, so it is validated like an option.
_resolve() {
    local _key="$1" _opt="$2" _stored _stored_src
    if [[ -n "${_opt}" ]]; then
        printf '%s user\n' "${_opt}"
        return 0
    fi
    _stored="$(enter_config_get "${CONFIG}" "${_key}")"
    _stored_src="$(enter_config_get "${CONFIG}" "${_key}.source")"
    if [[ -n "${_stored}" && "${_stored_src}" == "user" ]]; then
        if ! enter_value_ok "${_key}" "${_stored}"; then
            log_error "${CONFIG}: invalid value '${_stored}' for ${_key} (expected $(_expected "${_key}"))"
            return 1
        fi
        printf '%s user\n' "${_stored}"
        return 0
    fi
    printf '%s default\n' "$(enter_default "${_key}")"
}

# Resolve every decision into the globals and log each one.
_resolve_all() {
    local _r
    _r="$(_resolve auto-enter "${OPT_AUTO_ENTER}")" || return 1
    AUTO_ENTER="${_r% *}" AUTO_ENTER_SRC="${_r#* }"
    _r="$(_resolve terminal "${OPT_TERMINAL}")" || return 1
    TERMINAL="${_r% *}" TERMINAL_SRC="${_r#* }"
    _r="$(_resolve tmux "${OPT_TMUX}")" || return 1
    TMUX="${_r% *}" TMUX_SRC="${_r#* }"
    _r="$(_resolve box "${OPT_BOX}")" || return 1
    BOX="${_r% *}" BOX_SRC="${_r#* }"
    log_info "auto-enter: ${AUTO_ENTER} (${AUTO_ENTER_SRC})"
    log_info "terminal: ${TERMINAL} (${TERMINAL_SRC})"
    log_info "tmux: ${TMUX} (${TMUX_SRC})"
    log_info "box: ${BOX} (${BOX_SRC})"
}

# --- File actions (every one logged; --dry-run only logs) --------------------

# Replace a file atomically with the content on stdin: written next to the
# target, then renamed, so a reader never sees a half-written file.
_write_atomic() {
    local _target="$1" _tmp
    mkdir -p "$(dirname -- "${_target}")" || return 1
    _tmp="$(mktemp "${_target}.XXXXXX")" || return 1
    if cat >"${_tmp}" && mv -f "${_tmp}" "${_target}"; then
        return 0
    fi
    rm -f "${_tmp}"
    return 1
}

# Make file $1 hold exactly one managed block with body $2.
_block_write() {
    local _file="$1" _body="$2"
    if enter_block_present "${_file}" && [[ "$(enter_block_body "${_file}")" == "${_body}" ]]; then
        log_info "unchanged: ${_file} (managed block already up to date)"
        return 0
    fi
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "dry-run: would write ${_file} (managed block: ${_body})"
        return 0
    fi
    if ! enter_block_compose "${_file}" "${_body}" | _write_atomic "${_file}"; then
        log_error "failed to write ${_file}"
        return 1
    fi
    log_info "wrote: ${_file} (managed block: ${_body})"
}

# Remove the managed block from file $1. With $2 = report, an absent block
# is reported too (the restore path says what there was nothing to undo).
_block_remove() {
    local _file="$1" _report="${2:-}" _body
    if ! enter_block_present "${_file}"; then
        [[ "${_report}" == "report" ]] \
            && log_info "nothing to remove: ${_file} (no managed block)"
        return 0
    fi
    _body="$(enter_block_body "${_file}")"
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "dry-run: would remove managed block from ${_file}"
        return 0
    fi
    if ! enter_block_strip "${_file}" | _write_atomic "${_file}"; then
        log_error "failed to write ${_file}"
        return 1
    fi
    log_info "removed: ${_file} (managed block: ${_body})"
}

# Write the state file from the resolved decisions.
_config_write() {
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "dry-run: would write ${CONFIG}"
        return 0
    fi
    if ! _config_render | _write_atomic "${CONFIG}"; then
        log_error "failed to write ${CONFIG}"
        return 1
    fi
    log_info "wrote: ${CONFIG}"
}

_config_render() {
    printf '# worktool auto-enter state: written by "just box setup", read by "just box status".\n'
    printf '%s=%s\n%s.source=%s\n' \
        auto-enter "${AUTO_ENTER}" auto-enter "${AUTO_ENTER_SRC}" \
        terminal "${TERMINAL}" terminal "${TERMINAL_SRC}" \
        tmux "${TMUX}" tmux "${TMUX_SRC}" \
        box "${BOX}" box "${BOX_SRC}"
}

# --- Apply -------------------------------------------------------------------

# auto-enter yes: the terminal profile (ghostty) and, for tmux host, the
# tmux default-command; a block that the current decisions no longer need
# (terminal none, tmux inside) is removed if an earlier run left it.
_apply_enable() {
    local _ghostty _tmux_conf _rc=0
    _ghostty="$(enter_ghostty_config)"
    _tmux_conf="$(enter_tmux_conf)"
    if [[ "${TERMINAL}" == "ghostty" ]]; then
        if [[ "${TMUX}" == "inside" ]]; then
            _block_write "${_ghostty}" "command = distrobox enter ${BOX} -- tmux new -A -s main" || _rc=1
        else
            _block_write "${_ghostty}" "command = tmux new -A -s main" || _rc=1
        fi
    else
        log_info "terminal profile: none (nothing written; enter by hand: distrobox enter ${BOX})"
        _block_remove "${_ghostty}" || _rc=1
    fi
    if [[ "${TMUX}" == "host" ]]; then
        _block_write "${_tmux_conf}" "set -g default-command \"distrobox enter ${BOX}\"" || _rc=1
    else
        _block_remove "${_tmux_conf}" || _rc=1
    fi
    return "${_rc}"
}

# auto-enter no: restore the host shell by removing both managed blocks,
# reporting each file either way.
_apply_disable() {
    local _rc=0
    _block_remove "$(enter_ghostty_config)" report || _rc=1
    _block_remove "$(enter_tmux_conf)" report || _rc=1
    return "${_rc}"
}

# --- Main --------------------------------------------------------------------
setup_run() {
    _parse_args "$@" || return 2
    if [[ "${OPT_HELP}" -eq 1 ]]; then
        _usage
        return 0
    fi
    CONFIG="$(enter_config_path)"
    _resolve_all || return 1
    _config_write || return 1
    if [[ "${AUTO_ENTER}" == "yes" ]]; then
        _apply_enable
    else
        _apply_disable
    fi
}

# Guard: only run when executed directly, not when sourced (keeps the file
# importable by tests).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    setup_run "$@"
fi
