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
#   ./script/box/setup.sh                       # defaults: yes / detected / dev
#   ./script/box/setup.sh --box work            # enter another box
#   ./script/box/setup.sh --auto-enter no       # restore the host shell
#   ./script/box/setup.sh --dry-run             # log everything, write nothing
#   ./script/box/setup.sh --help                # usage
#
# Decisions (option (user) > stored user choice > default; each logged as
# `[INFO] <key>: <value> (<source>)`):
#   auto-enter  yes|no        default yes
#   terminal    ghostty|none  default ghostty when the ghostty EXECUTABLE is on
#                             PATH (or, secondary, a ghostty config dir exists)
#   box         <name>        default dev
#
# There is no tmux decision (issue #179). The terminal enters the box and
# gets the box's login shell; it starts no tmux. The old `-- tmux new -A -s
# main` attached to a HOST tmux server whenever one was running (distrobox
# shares /tmp with the host, and with it tmux's default socket), so the
# user got a host shell that looked like the box. A `tmux` the user starts
# in the box gets the box's own server (TMUX_TMPDIR, box/dev.ini), and
# worktool never reads or writes the host's ~/.tmux.conf.
#
# When `terminal` comes from the default, the BASIS of that default is
# logged too (`[INFO] terminal detected: <value> (<reason>)`): issue #175
# was a clean machine with /usr/bin/ghostty and no ~/.config/ghostty yet,
# resolved to `none` with nothing in the log to say why.
#
# State file: lib/config.sh (it alone knows where the file is),
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
# The body is shell SOURCE (ghostty runs a `command` without a `direct:`
# prefix through `/bin/sh -c`), so `<distrobox>` is written as a
# single-QUOTED shell word (issue #175 round 1).
#
# Quoting alone is not enough, though: the file is LINE-BASED, so a path
# holding a newline or a carriage return would split the managed body over
# two lines and make the whole file unparseable (ghostty answers
# `unknown field`). Such a path is REFUSED - whichever source it came from,
# and before anything at all is written (issue #175 round 2).
#
# The box's tmux environment (issue #179, codex round 4 on PR #232): on
# EVERY run, whatever the auto-enter and terminal decisions, one managed
# block goes into distrobox's own user config:
#     <config dir>/distrobox/distrobox.conf  (enter_distrobox_conf_body <box>)
# distrobox-enter sources that file before it copies the caller's
# environment into the box, and the line drops TMUX / TMUX_PANE when the
# run targets <box>: a `distrobox enter <box>` from a HOST tmux pane - the
# terminal's managed command, a shell, `-- <cmd>`, even `-- <real tmux>` -
# never hands the box the host server's socket. It is the box's isolation,
# not a terminal choice, so auto-enter no keeps it (lib/enter.sh has WHY).
#
# Managed block (begin/end marker lines, exactly one per file, replaced in
# place, user content and file mode preserved). Malformed markers (an
# unpaired BEGIN / END, END first, nested, two blocks, a marker with extra
# text) refuse the whole run before anything is written, exit 1 - a
# rewrite of such a file would lose user lines (codex round 4 on PR #232):
#   auto-enter yes, terminal ghostty:
#     existing <config dir>/ghostty/config.ghostty, else legacy config:
#       command = '<repo>/script/box/enter.sh' --distrobox '<distrobox>' --box '<box>'
#   auto-enter yes, terminal none: no terminal profile at all, a leftover
#     block removed.
#   auto-enter no: the block removed from either file, the removal reported.
# Both Ghostty files are validated first, with at most one block in total.
# Never create config.ghostty; migrate a legacy block to an existing new
# file on enable. Log the choice and warn for a host version below 1.3.0.
#
# Write order: the state file first, then distrobox.conf, then the profile.
# The stored values are validated before anything is written (a corrupt
# state file refuses the whole run, exit 1, no file changed); a profile
# write that fails afterwards leaves the state file already updated and
# exits 1 - `just box status` then shows the block as absent, and re-running
# `just box setup` (idempotent) completes the profiles.
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
OPT_BOX=""
OPT_DISTROBOX=""
OPT_DRY_RUN=0
OPT_HELP=0

# --- Resolved decisions (set by _resolve_all) --------------------------------
AUTO_ENTER="" TERMINAL="" BOX=""
AUTO_ENTER_SRC="" TERMINAL_SRC="" BOX_SRC=""

# The distrobox program the managed command names (set by _resolve_distrobox,
# only on the paths that write one).
DISTROBOX=""

# --- Usage -------------------------------------------------------------------
_usage() {
    config_fill >&2 <<'EOF'
Usage: setup.sh [--auto-enter yes|no] [--terminal ghostty|none]
                [--box <name>] [--distrobox <path>] [--dry-run]

Choose how a new terminal enters the worktool dev box, store the choice in
{state-file} and write the terminal profile for it.
Every decision is logged as `[INFO] <key>: <value> (default|user)`; read it
back any time with `just box status`.

  --auto-enter yes|no       Enter the box automatically (default: yes).
                            `no` removes the managed block and restores the
                            host shell, reporting what was removed.
  --terminal ghostty|none   Terminal profile to manage (default: ghostty when
                            the ghostty executable is on PATH, or when
                            $XDG_CONFIG_HOME/ghostty or ~/.config/ghostty
                            exists; else none). `none` writes no profile at
                            all; the decisions are still stored. ghostty
                            runs: <distrobox> enter <box> - the box's login
                            shell, no tmux. <distrobox> is the absolute
                            path this run resolves, so a terminal started
                            from the desktop can run it.
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
  {state-file}   the state file (key=value + key.source)
  $XDG_CONFIG_HOME/ghostty/config.ghostty (when it exists), else ghostty/config
                                     managed block: command = ...
Never creates config.ghostty. Validates both files before any write:
at most one managed block across both files; malformed markers refuse the
whole run and name both files. Enable moves the single block to the selected
file; disable removes it from either file. User content and modes are kept.
The selected file and reason are logged. A host Ghostty below 1.3.0 warns
when config.ghostty is selected; no executable means no version check.
  $XDG_CONFIG_HOME/distrobox/distrobox.conf
                                     managed block, on every run: drops
                                     TMUX / TMUX_PANE from `distrobox enter
                                     <box>`, so a host tmux pane's socket
                                     never reaches the box
No tmux is started and no host tmux config is touched: a tmux started in
the box gets the box's own server (TMUX_TMPDIR, set by box/dev.ini).

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

# Store option $1 (--auto-enter / --terminal / --box / --distrobox) = value $2 after validating the value. Returns 2 on an
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
        box)        OPT_BOX="$2" ;;
    esac
}

# Parse the WHOLE command line before anything runs, so an unknown option
# anywhere in it refuses the run as a whole. Returns 2 on a usage error.
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto-enter|--terminal|--box|--distrobox)
                if [[ $# -lt 2 ]]; then
                    _usage_error "$1 requires a value"
                    return 2
                fi
                _set_opt "$1" "$2" || return 2
                shift
                ;;
            --auto-enter=*|--terminal=*|--box=*|--distrobox=*)
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
    _problem="$(enter_config_check)" && return 0
    config_log error "" ": ${_problem}"
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
    _stored="$(config_get "${_key}")"
    _stored_src="$(config_get "${_key}.source")"
    if [[ -n "${_stored}" && "${_stored_src}" == "user" ]]; then
        printf '%s user\n' "${_stored}"
        return 0
    fi
    printf '%s default\n' "$(enter_default "${_key}")"
}

# Refuse the run when a managed file's markers are malformed (lib/enter.sh
# enter_block_check): the block helpers trust the markers, and rewriting a
# malformed file loses user lines. Every managed file is checked before
# ANYTHING is written - the state file included - so a refusal leaves the
# whole run untouched.
_blocks_check() {
    local _file _problem _rc=0 _count=0 _n
    local _legacy
    _legacy="$(enter_config_dir)/ghostty/config"
    for _file in "$(enter_distrobox_conf)" "${_legacy}" "${_legacy}.ghostty"; do
        if ! _problem="$(enter_block_check "${_file}")"; then
            log_error "${_file}: malformed worktool managed block markers: ${_problem}; nothing was written (fix or remove the markers, then re-run: just box setup)"
            _rc=1
        fi
    done
    for _file in "${_legacy}" "${_legacy}.ghostty"; do
        _n="$(enter_block_count "${_file}")" || return 1
        _count=$((_count + _n))
    done
    if [[ "${_count}" -gt 1 || "${_rc}" -ne 0 ]]; then
        log_error "managed block validation failed: ${_legacy} and ${_legacy}.ghostty (at most one block across both files); nothing was written"
        return 1
    fi
}

# Resolve every decision into the globals and log each one.
_resolve_all() {
    local _r _detected
    _config_check || return 1
    _blocks_check || return 1
    _r="$(_resolve auto-enter "${OPT_AUTO_ENTER}")" || return 1
    AUTO_ENTER="${_r% *}" AUTO_ENTER_SRC="${_r#* }"
    _r="$(_resolve terminal "${OPT_TERMINAL}")" || return 1
    TERMINAL="${_r% *}" TERMINAL_SRC="${_r#* }"
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
    log_info "box: ${BOX} (${BOX_SRC})"
    GHOSTTY_TARGET="$(enter_ghostty_target)"
    if [[ "${GHOSTTY_TARGET}" == *.ghostty ]]; then
        log_info "ghostty config: ${GHOSTTY_TARGET} (config.ghostty exists)"
        _ghostty_version_warn
    else
        log_info "ghostty config: ${GHOSTTY_TARGET} (config.ghostty absent; legacy fallback)"
    fi
    # Only the paths that WRITE a managed command need a distrobox, and
    # they need it before anything is written, so a refusal leaves the
    # whole run untouched.
    if [[ "${AUTO_ENTER}" == "yes" && "${TERMINAL}" == "ghostty" ]]; then
        _resolve_distrobox || return 1
    fi
}

# The new filename is unreadable by Ghostty before 1.3.0. Check the host
# executable only; its absence does not prevent configuring a profile.
_ghostty_version_warn() {
    local _exe _output _version _major _minor
    _exe="$(enter_which ghostty)" || return 0
    if ! _output="$("${_exe}" +version 2>&1)"; then
        log_warn "could not check ghostty +version: ${_output}"
        return 0
    fi
    if [[ "${_output}" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        _version="${BASH_REMATCH[0]}"
        _major="${BASH_REMATCH[1]}" _minor="${BASH_REMATCH[2]}"
        if (( 10#${_major} < 1 || (10#${_major} == 1 && 10#${_minor} < 3) )); then
            log_warn "ghostty ${_version} does not read ${GHOSTTY_TARGET} (requires 1.3.0 or newer)"
        fi
    else
        log_warn "could not parse ghostty +version: ${_output}"
    fi
    return 0
}

# Resolve the distrobox the managed command will name into DISTROBOX and
# log the basis. Returns 1 - and the caller refuses the whole run before
# writing anything - when there is none, or when the resolved path cannot
# be encoded into the block this run would write (a newline or carriage
# return anywhere). The rule applies to BOTH sources of the path, the
# option and PATH, because it is about what the managed FILE can hold.
#
# Issue #175 round 1: the first attempt wrote the bare name with a WARN
# when nothing resolved. That handed the user exactly the configuration
# the real machine failed on - a terminal window that opens and closes -
# and `just box status` cannot rescue it, because nothing about that
# failure sends anyone to run status. setup knows here that the command
# cannot work, so it refuses and says what to do instead.
_resolve_distrobox() {
    if ! enter_path_single_line "${SCRIPT_DIR}/enter.sh"; then
        log_error "wrapper: $(enter_show_control "${SCRIPT_DIR}/enter.sh") holds a newline or carriage return, which cannot be written into the line-based ghostty config (move the repo to a path without one); nothing was written"
        return 1
    fi
    if [[ -n "${OPT_DISTROBOX}" ]]; then
        DISTROBOX="${OPT_DISTROBOX}"
        log_info "distrobox: ${DISTROBOX} (--distrobox; absolute path written into the managed command)"
    elif DISTROBOX="$(enter_distrobox_program)"; then
        log_info "distrobox: ${DISTROBOX} (absolute path written into the managed command)"
    else
        log_error "distrobox: not found on PATH - the managed command must name an absolute path a terminal launched from the desktop can run (install distrobox, or pass --distrobox <path>); nothing was written"
        return 1
    fi
    # The managed file is line-based, so a path holding a newline or a
    # carriage return cannot be written into it whatever the shell quoting
    # says (issue #175 round 2). The diagnostic shows the
    # control character rather than printing it, so the error stays one
    # line.
    if ! enter_path_single_line "${DISTROBOX}"; then
        log_error "distrobox: $(enter_show_control "${DISTROBOX}") holds a newline or carriage return, which cannot be written into the line-based ghostty config (install distrobox at a path without one); nothing was written"
        return 1
    fi
}

# --- File actions (every one logged; --dry-run only logs) --------------------

_ghostty_reload_hint() {
    case "$1" in
        "$(enter_config_dir)/ghostty/config"|"$(enter_config_dir)/ghostty/config.ghostty")
            log_info "Ghostty config changed: a running Ghostty must reload its config (Linux default: Ctrl+Shift+,). Reload is asynchronous; wait until the config takes effect before opening a new window, or start a new Ghostty process first. Keep your existing windows open."
            ;;
    esac
}

# Make file $1 hold exactly one managed block with body $2. The markers were
# validated by _blocks_check before anything was written, so the file holds
# no block or exactly one.
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
    _ghostty_reload_hint "${_file}"
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
    _ghostty_reload_hint "${_file}"
}

# Set the resolved decisions (and their sources) in the state file IN
# PLACE (lib/config.sh config_set): the state file is shared - assemble
# records home= there, the user adds link= lines - so only setup's own
# keys change and every other line stays byte-for-byte.
_config_write() {
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        config_log info "dry-run: would write "
        return 0
    fi
    if ! config_set \
        auto-enter "${AUTO_ENTER}" auto-enter.source "${AUTO_ENTER_SRC}" \
        terminal "${TERMINAL}" terminal.source "${TERMINAL_SRC}" \
        box "${BOX}" box.source "${BOX_SRC}"; then
        config_log error "failed to write "
        return 1
    fi
    config_log info "wrote: "
}

# --- Apply -------------------------------------------------------------------

# Make the status remedy (re-run setup) repair a lost wrapper execute bit.
# Refuse a missing or unrepairable target before writing managed files.
_prepare_wrapper() {
    local _path="${SCRIPT_DIR}/enter.sh"
    [[ "${AUTO_ENTER}" == yes && "${TERMINAL}" == ghostty ]] || return 0
    if [[ ! -f "${_path}" ]]; then
        log_error "wrapper: ${_path} is missing; restore the repo, then re-run: just box setup; nothing was written"
        return 1
    fi
    [[ ! -x "${_path}" ]] || return 0
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "dry-run: would restore wrapper execute permission: ${_path}"
        return 0
    fi
    if ! chmod u+x -- "${_path}"; then
        log_error "wrapper: cannot restore execute permission: ${_path}; check repo ownership and permissions, then re-run: just box setup; no managed files were written"
        return 1
    fi
    log_info "restored wrapper execute permission: ${_path}"
}

# auto-enter yes: the terminal profile (ghostty); a block that the current
# decisions no longer need (terminal none) is removed if an earlier run
# left it.
_apply_enable() {
    if [[ "${TERMINAL}" == "ghostty" ]]; then
        _apply_ghostty
    else
        _apply_no_terminal
    fi
}

# terminal ghostty: the ghostty block enters the box and runs nothing after
# it - the box's login shell answers (issue #179: no tmux).
_apply_ghostty() {
    local _body _other
    _body="command = $(enter_sh_squote "${SCRIPT_DIR}/enter.sh") --distrobox $(enter_sh_squote "${DISTROBOX}") --box $(enter_sh_squote "${BOX}")"
    _other="$(enter_config_dir)/ghostty/config"
    if [[ "${GHOSTTY_TARGET}" == "${_other}" ]]; then
        _other+=".ghostty"
    fi
    if enter_block_present "${_other}"; then
        _ghostty_move "${_other}" "${GHOSTTY_TARGET}" "${_body}"
    else
        _block_write "${GHOSTTY_TARGET}" "${_body}"
    fi
}

# Prepare both contents before either write. Each replacement is atomic;
# a failure between the replacements is reported, never silently ignored.
_ghostty_move() {
    local _source="$1" _target="$2" _body="$3" _stage _rc=0
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "dry-run: would move managed block from ${_source} to ${_target}"
        return 0
    fi
    if ! _stage="$(mktemp -d)"; then
        log_error "failed to prepare move: ${_source} -> ${_target}"
        return 1
    fi
    if ! enter_block_strip "${_source}" >"${_stage}/source" \
        || ! enter_block_compose "${_target}" "${_body}" >"${_stage}/target"; then
        log_error "failed to prepare move: ${_source} -> ${_target}"
        _rc=1
    elif ! config_write_atomic "${_target}" <"${_stage}/target"; then
        log_error "failed to write ${_target} while moving from ${_source}"
        _rc=1
    elif ! config_write_atomic "${_source}" <"${_stage}/source"; then
        log_error "failed to write ${_source} after writing ${_target}; inspect both files before re-running"
        _rc=1
    else
        log_info "moved: ${_source} -> ${_target} (managed block)"
        _ghostty_reload_hint "${_target}"
    fi
    rm -rf -- "${_stage}" || return 1
    return "${_rc}"
}

# terminal none: no terminal profile is written at all (doc/enter.md); the
# decisions are still stored for `just box status`. A block an earlier
# ghostty run left is removed.
#
# The hint below keeps the BARE name on purpose: nothing is being written
# to a file here, it is a line for the user to type in their own
# interactive shell, whose PATH does hold ~/.local/bin. The absolute path
# of issue #175 is for the managed command, which a desktop session runs.
_apply_no_terminal() {
    log_info "terminal profile: none (nothing written; enter by hand: distrobox enter ${BOX})"
    _ghostty_remove
}

# auto-enter no: restore the host shell by removing the managed block,
# reporting the file either way.
_apply_disable() {
    _ghostty_remove report
}

# A single block may still live in the non-target file before migration.
_ghostty_remove() {
    local _target="${GHOSTTY_TARGET}" _other
    _other="$(enter_config_dir)/ghostty/config"
    [[ "${_target}" != "${_other}" ]] || _other+=".ghostty"
    if enter_block_present "${_other}"; then
        _block_remove "${_other}" "${1:-}"
    else
        _block_remove "${_target}" "${1:-}"
    fi
}

# Every run: the distrobox.conf block that keeps a caller's TMUX / TMUX_PANE
# out of box BOX (lib/enter.sh enter_distrobox_conf_body has WHY). It is the
# box's tmux isolation, not a terminal choice, so auto-enter no keeps it.
_apply_box_env() {
    _block_write "$(enter_distrobox_conf)" "$(enter_distrobox_conf_body "${BOX}")"
}

# --- Main --------------------------------------------------------------------
setup_run() {
    _parse_args "$@" || return 2
    if [[ "${OPT_HELP}" -eq 1 ]]; then
        _usage
        return 0
    fi
    _resolve_all || return 1
    _prepare_wrapper || return 1
    _config_write || return 1
    _apply_box_env || return 1
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
