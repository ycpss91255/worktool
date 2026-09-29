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
#   terminal    ghostty|none  default ghostty when the ghostty EXECUTABLE is on
#                             PATH (or, secondary, a ghostty config dir exists)
#   tmux        inside|host   default inside
#   box         <name>        default dev
#
# When `terminal` comes from the default, the BASIS of that default is
# logged too (`[INFO] terminal detected: <value> (<reason>)`): issue #175
# was a clean machine with /usr/bin/ghostty and no ~/.config/ghostty yet,
# resolved to `none` with nothing in the log to say why.
#
# State file: $XDG_CONFIG_HOME/worktool/config (~/.config/worktool/config),
# `<key>=<value>` plus `<key>.source=default|user` per key. A user choice
# persists across runs until overridden; default keys are recomputed.
# The file is shared (assemble records home=, the user adds link= lines):
# setup sets only its own keys, in place, through lib/config.sh, and keeps
# every other line byte-for-byte.
#
# `<distrobox>` below is the ABSOLUTE path of the distrobox this run
# resolved (`[INFO] distrobox: ...`), never the bare name: a terminal the
# desktop starts inherits the systemd user manager's PATH, which does not
# hold ~/.local/bin, and the bare name died there with `/bin/sh: 1:
# distrobox: not found` (issue #175). With nothing on PATH the run is
# REFUSED (exit 1, nothing written) instead of writing a command already
# known to fail; `--distrobox <path>` names one explicitly.
#
# Both bodies are shell SOURCE (ghostty runs a `command` without a
# `direct:` prefix through `/bin/sh -c`; tmux runs `default-command` the
# same way), so `<distrobox>` is written as a QUOTED shell word: single
# quotes in the ghostty body, and double quotes inside tmux's own
# single-quoted value (issue #175 round 1).
#
# Quoting alone is not enough, though: both files are LINE-BASED, so a path
# holding a newline or a carriage return would split the managed body over
# two lines and make the whole file unparseable (ghostty answers
# `unknown field`). Such a path is REFUSED - whichever source it came from,
# and before anything at all is written (issue #175 round 2).
#
# Managed blocks (begin/end marker lines, exactly one per file, replaced in
# place, user content and file mode preserved):
#   auto-enter yes, terminal ghostty, tmux inside:
#     <config dir>/ghostty/config  command = '<distrobox>' enter <box> -- tmux new -A -s main
#   auto-enter yes, terminal ghostty, tmux host:
#     <config dir>/ghostty/config  command = tmux new -A -s main
#     ~/.tmux.conf                 set -g default-command '"<distrobox>" enter <box>'
#   auto-enter yes, terminal none: no terminal profile at all (whatever tmux
#     says: the tmux.conf block only serves the ghostty+host pair), leftover
#     blocks removed.
#   auto-enter no: both blocks removed, each removal reported.
#
# Write order: the state file first, then the profiles. The stored values
# are validated before anything is written (a corrupt state file refuses the
# whole run, exit 1, no file changed); a profile write that fails afterwards
# leaves the state file already updated and exits 1 - `just box status` then
# shows the block as absent, and re-running `just box setup` (idempotent)
# completes the profiles.
#
# This script owns its option validation: an unknown option or an invalid
# value is refused with `setup.sh: ... (see --help)` on stderr, exit 2,
# before anything runs. All diagnostics go to STDERR via lib/log.sh.
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

# --- Option state (set by _parse_args) ---------------------------------------
OPT_AUTO_ENTER=""
OPT_TERMINAL=""
OPT_TMUX=""
OPT_BOX=""
OPT_DISTROBOX=""
OPT_DRY_RUN=0
OPT_HELP=0

# --- Resolved decisions (set by _resolve_all) --------------------------------
CONFIG=""
AUTO_ENTER="" TERMINAL="" TMUX="" BOX=""
AUTO_ENTER_SRC="" TERMINAL_SRC="" TMUX_SRC="" BOX_SRC=""

# The distrobox program the managed command names (set by _resolve_distrobox,
# only on the paths that write one).
DISTROBOX=""

# --- Usage -------------------------------------------------------------------
_usage() {
    cat >&2 <<'EOF'
Usage: setup.sh [--auto-enter yes|no] [--terminal ghostty|none]
                [--tmux inside|host] [--box <name>] [--distrobox <path>]
                [--dry-run]

Choose how a new terminal enters the worktool dev box, store the choice in
$XDG_CONFIG_HOME/worktool/config and write the terminal profile for it.
Every decision is logged as `[INFO] <key>: <value> (default|user)`; read it
back any time with `just box status`.

  --auto-enter yes|no       Enter the box automatically (default: yes).
                            `no` removes the managed blocks and restores the
                            host shell, reporting what was removed.
  --terminal ghostty|none   Terminal profile to manage (default: ghostty when
                            the ghostty executable is on PATH, or when
                            $XDG_CONFIG_HOME/ghostty or ~/.config/ghostty
                            exists; else none). `none` writes no profile at
                            all, not even ~/.tmux.conf; the decisions are
                            still stored.
  --tmux inside|host        Where tmux runs (default: inside): inside the box
                            (ghostty: <distrobox> enter <box> -- tmux new -A
                            -s main) or on the host (ghostty: tmux new -A -s
                            main; ~/.tmux.conf: set -g default-command
                            "<distrobox> enter <box>"). <distrobox> is the
                            absolute path this run resolves, so a terminal
                            started from the desktop can run it.
  --box <name>              Box to enter (default: dev).
  --distrobox <path>        Absolute path of the distrobox executable to write
                            into the managed command (default: the one on
                            PATH). With none on PATH and no --distrobox the
                            run is refused: a bare `distrobox` is exactly the
                            command a desktop-launched terminal cannot find.
  --dry-run                 Log every decision and file action; write nothing.
  -h, --help                Show this help and exit.

Files (all under HOME / XDG_CONFIG_HOME; a managed block is delimited by
`# BEGIN worktool managed block ...` / `# END worktool managed block`):
  $XDG_CONFIG_HOME/worktool/config   the state file (key=value + key.source)
  $XDG_CONFIG_HOME/ghostty/config    managed block: command = ...
  ~/.tmux.conf                       managed block (terminal ghostty + tmux host only)

The state file is validated before anything is written: a corrupt value in
it (whatever its `.source`) is refused with `[ERROR] <file>: invalid value
...`, exit 1, and no file is changed. A distrobox that cannot be resolved
is refused the same way, before anything is written. The state file is
written first, then the profiles; existing files keep their mode.
EOF
}

# Refuse the command line: one line on stderr (the caller returns 2; nothing
# has run yet).
_usage_error() {
    printf 'setup.sh: %s (see --help)\n' "$1" >&2
}

# --- Argument parsing --------------------------------------------------------

# Store option $1 (--auto-enter / --terminal / --tmux / --box /
# --distrobox) = value $2 after validating the value. Returns 2 on an
# invalid value.
#
# --distrobox is not a stored decision, so it has its own rule rather than
# a state-file one: only an absolute path to an executable FILE can go into
# a managed command (the same contract enter_which enforces for PATH).
_set_opt() {
    local _key="${1#--}"
    if [[ "${_key}" == "distrobox" ]]; then
        if [[ "$2" != /* || ! -f "$2" || ! -x "$2" ]]; then
            _usage_error "invalid value '$2' for $1 (expected an absolute path to an executable file)"
            return 2
        fi
        OPT_DISTROBOX="$2"
        return 0
    fi
    if ! enter_value_ok "${_key}" "$2"; then
        _usage_error "invalid value '$2' for $1 (expected $(enter_expected "${_key}"))"
        return 2
    fi
    case "${_key}" in
        auto-enter) OPT_AUTO_ENTER="$2" ;;
        terminal)   OPT_TERMINAL="$2" ;;
        tmux)       OPT_TMUX="$2" ;;
        box)        OPT_BOX="$2" ;;
    esac
}

# Parse the WHOLE command line before anything runs, so an unknown option
# anywhere in it refuses the run as a whole. Returns 2 on a usage error.
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto-enter|--terminal|--tmux|--box|--distrobox)
                if [[ $# -lt 2 ]]; then
                    _usage_error "$1 requires a value"
                    return 2
                fi
                _set_opt "$1" "$2" || return 2
                shift
                ;;
            --auto-enter=*|--terminal=*|--tmux=*|--box=*|--distrobox=*)
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

# Refuse a corrupt state file before any decision is taken: every stored
# value is validated whatever its `.source` says (the file is user-editable,
# so a default-sourced line can be wrong too), and nothing is written.
_config_check() {
    local _problem
    _problem="$(enter_config_check "${CONFIG}")" && return 0
    log_error "${CONFIG}: ${_problem}"
    return 1
}

# Print `<value> <source>` for key $1 given its option value $2: the option
# wins (user), then a stored choice whose source is user, then the default.
# The stored values were validated as a whole by _config_check.
_resolve() {
    local _key="$1" _opt="$2" _stored _stored_src
    if [[ -n "${_opt}" ]]; then
        printf '%s user\n' "${_opt}"
        return 0
    fi
    _stored="$(enter_config_get "${CONFIG}" "${_key}")"
    _stored_src="$(enter_config_get "${CONFIG}" "${_key}.source")"
    if [[ -n "${_stored}" && "${_stored_src}" == "user" ]]; then
        printf '%s user\n' "${_stored}"
        return 0
    fi
    printf '%s default\n' "$(enter_default "${_key}")"
}

# Resolve every decision into the globals and log each one.
_resolve_all() {
    local _r _detected
    _config_check || return 1
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
    # Only a DEFAULT has a detection basis to report; a user-forced value
    # was not detected at all, and saying otherwise would mislead.
    if [[ "${TERMINAL_SRC}" == "default" ]]; then
        _detected="$(enter_terminal_detect)"
        log_info "terminal detected: ${_detected%% *} (${_detected#* })"
    fi
    log_info "tmux: ${TMUX} (${TMUX_SRC})"
    log_info "box: ${BOX} (${BOX_SRC})"
    # Only the paths that WRITE a managed command need a distrobox, and
    # they need it before anything is written, so a refusal leaves the
    # whole run untouched.
    if [[ "${AUTO_ENTER}" == "yes" && "${TERMINAL}" == "ghostty" ]]; then
        _resolve_distrobox || return 1
    fi
}

# Resolve the distrobox the managed command will name into DISTROBOX and
# log the basis. Returns 1 - and the caller refuses the whole run before
# writing anything - when there is none, or when the resolved path cannot
# be encoded into the blocks this run would write (a newline or carriage
# return anywhere; a single quote when ~/.tmux.conf is also written). The
# two encoding rules apply to BOTH sources of the path, the option and
# PATH, because they are about what the managed FILES can hold.
#
# Issue #175 round 1: the first attempt wrote the bare name with a WARN
# when nothing resolved. That handed the user exactly the configuration
# the real machine failed on - a terminal window that opens and closes -
# and `just box status` cannot rescue it, because nothing about that
# failure sends anyone to run status. setup knows here that the command
# cannot work, so it refuses and says what to do instead.
_resolve_distrobox() {
    if [[ -n "${OPT_DISTROBOX}" ]]; then
        DISTROBOX="${OPT_DISTROBOX}"
        log_info "distrobox: ${DISTROBOX} (--distrobox; absolute path written into the managed command)"
    elif DISTROBOX="$(enter_distrobox_program)"; then
        log_info "distrobox: ${DISTROBOX} (absolute path written into the managed command)"
    else
        log_error "distrobox: not found on PATH - the managed command must name an absolute path a terminal launched from the desktop can run (install distrobox, or pass --distrobox <path>); nothing was written"
        return 1
    fi
    # Both managed files are line-based, so a path holding a newline or a
    # carriage return cannot be written into either of them whatever the
    # shell quoting says (issue #175 round 2). The diagnostic shows the
    # control character rather than printing it, so the error stays one
    # line.
    if ! enter_path_single_line "${DISTROBOX}"; then
        log_error "distrobox: $(enter_show_control "${DISTROBOX}") holds a newline or carriage return, which cannot be written into the line-based ghostty config or ~/.tmux.conf (install distrobox at a path without one); nothing was written"
        return 1
    fi
    # The ~/.tmux.conf body nests a shell command inside a tmux
    # single-quoted value, and tmux has NO escape inside single quotes, so
    # a path holding one cannot be delivered through it. Refuse rather
    # than write a file that would not parse the way it reads.
    if [[ "${TMUX}" == "host" && "${DISTROBOX}" == *"'"* ]]; then
        log_error "distrobox: ${DISTROBOX} holds a single quote, which cannot be encoded safely in the ~/.tmux.conf managed block (use --tmux inside, or install distrobox at a path without one); nothing was written"
        return 1
    fi
}

# --- File actions (every one logged; --dry-run only logs) --------------------

# Make file $1 hold exactly one managed block with body $2. Only ONE block
# with that body counts as up to date; duplicates are collapsed on rewrite.
_block_write() {
    local _file="$1" _body="$2"
    if [[ "$(enter_block_count "${_file}")" -eq 1 \
        && "$(enter_block_body "${_file}")" == "${_body}" ]]; then
        log_info "unchanged: ${_file} (managed block already up to date)"
        return 0
    fi
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "dry-run: would write ${_file} (managed block: ${_body})"
        return 0
    fi
    if ! enter_block_compose "${_file}" "${_body}" | config_write_atomic "${_file}"; then
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
    if ! enter_block_strip "${_file}" | config_write_atomic "${_file}"; then
        log_error "failed to write ${_file}"
        return 1
    fi
    log_info "removed: ${_file} (managed block: ${_body})"
}

# Set the resolved decisions (and their sources) in the state file IN
# PLACE (lib/config.sh config_set): the state file is shared - assemble
# records home= there, the user adds link= lines - so only setup's own
# keys change and every other line stays byte-for-byte.
_config_write() {
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "dry-run: would write ${CONFIG}"
        return 0
    fi
    if ! config_set "${CONFIG}" \
        auto-enter "${AUTO_ENTER}" auto-enter.source "${AUTO_ENTER_SRC}" \
        terminal "${TERMINAL}" terminal.source "${TERMINAL_SRC}" \
        tmux "${TMUX}" tmux.source "${TMUX_SRC}" \
        box "${BOX}" box.source "${BOX_SRC}"; then
        log_error "failed to write ${CONFIG}"
        return 1
    fi
    log_info "wrote: ${CONFIG}"
}

# --- Apply -------------------------------------------------------------------

# auto-enter yes: the terminal profile (ghostty) and, for tmux host, the
# tmux default-command; a block that the current decisions no longer need
# (terminal none, tmux inside) is removed if an earlier run left it.
_apply_enable() {
    if [[ "${TERMINAL}" == "ghostty" ]]; then
        _apply_ghostty
    else
        _apply_no_terminal
    fi
}

# terminal ghostty: the ghostty block for the tmux placement, plus the
# tmux.conf block for tmux host (removed again for tmux inside).
_apply_ghostty() {
    local _ghostty _tmux_conf _rc=0
    _ghostty="$(enter_ghostty_config)"
    _tmux_conf="$(enter_tmux_conf)"
    # DISTROBOX was resolved (and the run refused if it could not be) in
    # _resolve_all, before any file was touched. Both bodies are shell
    # source, so the path goes in as a quoted shell word.
    if [[ "${TMUX}" == "inside" ]]; then
        _block_write "${_ghostty}" \
            "command = $(enter_sh_squote "${DISTROBOX}") enter ${BOX} -- tmux new -A -s main" || _rc=1
        _block_remove "${_tmux_conf}" || _rc=1
    else
        _block_write "${_ghostty}" "command = tmux new -A -s main" || _rc=1
        _block_write "${_tmux_conf}" \
            "set -g default-command '$(enter_sh_dquote "${DISTROBOX}") enter ${BOX}'" || _rc=1
    fi
    return "${_rc}"
}

# terminal none: no terminal profile is written at all (doc/enter.md), so
# the tmux.conf block - which only serves the ghostty+host pair - is not
# written either; the tmux decision is still stored for `just box status`.
# Blocks an earlier ghostty run left are removed.
#
# The hint below keeps the BARE name on purpose: nothing is being written
# to a file here, it is a line for the user to type in their own
# interactive shell, whose PATH does hold ~/.local/bin. The absolute path
# of issue #175 is for the managed command, which a desktop session runs.
_apply_no_terminal() {
    local _rc=0
    log_info "terminal profile: none (nothing written; enter by hand: distrobox enter ${BOX})"
    _block_remove "$(enter_ghostty_config)" || _rc=1
    _block_remove "$(enter_tmux_conf)" || _rc=1
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
