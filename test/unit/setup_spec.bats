#!/usr/bin/env bats
# test/unit/setup_spec.bats - script/box/setup.sh: user-selectable auto-enter
# (M3, issue #21)
#
# Written test-first (RED) before the script exists, then the script is
# implemented to pass (GREEN).
#
# Contract under test:
#   - Every decision is resolved as option (user) > stored user choice >
#     default, and logged on stderr as `[INFO] <key>: <value> (<source>)`:
#     auto-enter yes|no (default yes), terminal ghostty|none (default ghostty
#     when a ghostty config dir exists, else none), tmux inside|host (default
#     inside), box <name> (default dev).
#   - The decisions land in ONE state file, $XDG_CONFIG_HOME/worktool/config
#     (default ~/.config/worktool/config): `<key>=<value>` plus
#     `<key>.source=default|user` per key. User choices persist across runs;
#     default keys are recomputed on every run.
#   - auto-enter yes + terminal ghostty writes ONE managed block (begin/end
#     marker lines) into $XDG_CONFIG_HOME/ghostty/config: tmux inside ->
#     `command = distrobox enter <box> -- tmux new -A -s main`; tmux host ->
#     `command = tmux new -A -s main` plus a managed block in ~/.tmux.conf
#     (`set -g default-command "distrobox enter <box>"`). Re-runs are
#     idempotent (the block is replaced in place, never duplicated); user
#     content around the block is preserved.
#   - auto-enter no removes both managed blocks and reports each removal.
#   - Every file written / removed is logged; --dry-run logs what it would do
#     and writes NOTHING (not even the state file).
#   - The script owns its CLI: --help / -h exit 0; an unknown option or an
#     invalid value is refused with `setup.sh: ... (see --help)` on stderr,
#     exit 2, before anything is touched.
#
# Every path comes from HOME / XDG_CONFIG_HOME, so each case runs against a
# throwaway HOME under BATS_TEST_TMPDIR: the real home is never read or
# written.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    SETUP="${REPO_ROOT}/script/box/setup.sh"
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CONFIG_HOME
    mkdir -p "${HOME}"
    CONFIG="${HOME}/.config/worktool/config"
    GHOSTTY="${HOME}/.config/ghostty/config"
    TMUX_CONF="${HOME}/.tmux.conf"
    BEGIN="# BEGIN worktool managed block (just box setup; do not edit)"
    END="# END worktool managed block"
    CMD_INSIDE="command = distrobox enter dev -- tmux new -A -s main"
    CMD_HOST="command = tmux new -A -s main"
    TMUX_BODY='set -g default-command "distrobox enter dev"'
}

# Number of managed-block begin markers in file $1 (0 when absent).
_block_count() {
    [[ -f "$1" ]] || { printf '0\n'; return 0; }
    grep -cxF "${BEGIN}" "$1" || true
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# --- defaults + logging ------------------------------------------------------

@test "defaults (no ghostty dir): yes / none / inside / dev, each logged as (default), state file written with sources" {
    run "${SETUP}"
    assert_success
    assert_line "[INFO] auto-enter: yes (default)"
    assert_line "[INFO] terminal: none (default)"
    assert_line "[INFO] tmux: inside (default)"
    assert_line "[INFO] box: dev (default)"
    assert_line "[INFO] wrote: ${CONFIG}"
    run cat "${CONFIG}"
    assert_line "auto-enter=yes"
    assert_line "auto-enter.source=default"
    assert_line "terminal=none"
    assert_line "terminal.source=default"
    assert_line "tmux=inside"
    assert_line "tmux.source=default"
    assert_line "box=dev"
    assert_line "box.source=default"
    assert [ ! -e "${GHOSTTY}" ]
    assert [ ! -e "${TMUX_CONF}" ]
}

@test "terminal none with auto-enter yes says no terminal profile is managed and names the manual command" {
    run "${SETUP}"
    assert_success
    assert_line "[INFO] terminal profile: none (nothing written; enter by hand: distrobox enter dev)"
}

@test "terminal defaults to ghostty when ~/.config/ghostty exists: block written there, logged as (default)" {
    mkdir -p "${HOME}/.config/ghostty"
    run "${SETUP}"
    assert_success
    assert_line "[INFO] terminal: ghostty (default)"
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_INSIDE})"
    run cat "${GHOSTTY}"
    assert_line --index 0 "${BEGIN}"
    assert_line --index 1 "${CMD_INSIDE}"
    assert_line --index 2 "${END}"
    assert_equal "${#lines[@]}" 3
    assert [ ! -e "${TMUX_CONF}" ]
}

@test "XDG_CONFIG_HOME relocates both the state file and the ghostty config" {
    local _xdg="${BATS_TEST_TMPDIR}/xdg"
    mkdir -p "${_xdg}/ghostty"
    XDG_CONFIG_HOME="${_xdg}" run "${SETUP}"
    assert_success
    assert_line "[INFO] terminal: ghostty (default)"
    assert_line "[INFO] wrote: ${_xdg}/worktool/config"
    assert_line "[INFO] wrote: ${_xdg}/ghostty/config (managed block: ${CMD_INSIDE})"
    assert [ -f "${_xdg}/worktool/config" ]
    assert [ ! -e "${CONFIG}" ]
    assert [ ! -e "${GHOSTTY}" ]
}

# --- user overrides ----------------------------------------------------------

@test "user overrides are logged as (user) and stored with source=user" {
    run "${SETUP}" --auto-enter yes --terminal ghostty --tmux host --box work
    assert_success
    assert_line "[INFO] auto-enter: yes (user)"
    assert_line "[INFO] terminal: ghostty (user)"
    assert_line "[INFO] tmux: host (user)"
    assert_line "[INFO] box: work (user)"
    run cat "${CONFIG}"
    assert_line "auto-enter.source=user"
    assert_line "terminal=ghostty"
    assert_line "terminal.source=user"
    assert_line "tmux=host"
    assert_line "tmux.source=user"
    assert_line "box=work"
    assert_line "box.source=user"
}

@test "--key=value spelling is accepted for every value option" {
    run "${SETUP}" --auto-enter=yes --terminal=ghostty --tmux=host --box=work
    assert_success
    assert_line "[INFO] terminal: ghostty (user)"
    assert_line "[INFO] tmux: host (user)"
    assert_line "[INFO] box: work (user)"
}

@test "a stored user choice persists across runs; a default key is recomputed" {
    run "${SETUP}" --box work
    assert_success
    assert_line "[INFO] terminal: none (default)"
    # Second run, no option: box stays the user's; terminal is re-detected.
    mkdir -p "${HOME}/.config/ghostty"
    run "${SETUP}"
    assert_success
    assert_line "[INFO] box: work (user)"
    assert_line "[INFO] terminal: ghostty (default)"
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: command = distrobox enter work -- tmux new -A -s main)"
}

# --- ghostty block: exactly once, idempotent, user content preserved ---------

@test "the ghostty block is written exactly once and a re-run is idempotent (unchanged)" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n' >"${GHOSTTY}"
    run "${SETUP}" --terminal ghostty
    assert_success
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_INSIDE})"
    local _first
    _first="$(cat "${GHOSTTY}")"
    assert_equal "$(_block_count "${GHOSTTY}")" "1"

    run "${SETUP}" --terminal ghostty
    assert_success
    assert_line "[INFO] unchanged: ${GHOSTTY} (managed block already up to date)"
    assert_equal "$(_block_count "${GHOSTTY}")" "1"
    assert_equal "$(cat "${GHOSTTY}")" "${_first}"
    run cat "${GHOSTTY}"
    assert_line --index 0 "theme = dark"
    assert_line --index 1 "${BEGIN}"
    assert_line --index 2 "${CMD_INSIDE}"
    assert_line --index 3 "${END}"
    assert_equal "${#lines[@]}" 4
}

@test "a changed decision replaces the block in place: user lines before and after it survive" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n%s\n%s\n%s\nfont-size = 12\n' \
        "${BEGIN}" "${CMD_INSIDE}" "${END}" >"${GHOSTTY}"
    run "${SETUP}" --terminal ghostty --tmux host
    assert_success
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_HOST})"
    assert_equal "$(_block_count "${GHOSTTY}")" "1"
    run cat "${GHOSTTY}"
    assert_line --index 0 "theme = dark"
    assert_line --index 1 "${BEGIN}"
    assert_line --index 2 "${CMD_HOST}"
    assert_line --index 3 "${END}"
    assert_line --index 4 "font-size = 12"
    assert_equal "${#lines[@]}" 5
    refute_line "${CMD_INSIDE}"
}

# --- tmux host variant -------------------------------------------------------

@test "--tmux host: ghostty runs tmux on the host and ~/.tmux.conf gets the default-command block" {
    run "${SETUP}" --terminal ghostty --tmux host
    assert_success
    assert_line "[INFO] tmux: host (user)"
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_HOST})"
    assert_line "[INFO] wrote: ${TMUX_CONF} (managed block: ${TMUX_BODY})"
    run cat "${TMUX_CONF}"
    assert_line --index 0 "${BEGIN}"
    assert_line --index 1 "${TMUX_BODY}"
    assert_line --index 2 "${END}"
    assert_equal "${#lines[@]}" 3
}

@test "switching back to --tmux inside removes the ~/.tmux.conf block and reports it" {
    run "${SETUP}" --terminal ghostty --tmux host
    assert_success
    run "${SETUP}" --tmux inside
    assert_success
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_INSIDE})"
    assert_line "[INFO] removed: ${TMUX_CONF} (managed block: ${TMUX_BODY})"
    assert_equal "$(_block_count "${TMUX_CONF}")" "0"
}

# --- auto-enter no: restore the host shell -----------------------------------

@test "--auto-enter no removes both managed blocks, reports each, keeps user content" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n' >"${GHOSTTY}"
    printf 'set -g mouse on\n' >"${TMUX_CONF}"
    run "${SETUP}" --terminal ghostty --tmux host
    assert_success
    assert_equal "$(_block_count "${GHOSTTY}")" "1"
    assert_equal "$(_block_count "${TMUX_CONF}")" "1"

    run "${SETUP}" --auto-enter no
    assert_success
    assert_line "[INFO] auto-enter: no (user)"
    assert_line "[INFO] removed: ${GHOSTTY} (managed block: ${CMD_HOST})"
    assert_line "[INFO] removed: ${TMUX_CONF} (managed block: ${TMUX_BODY})"
    assert_equal "$(_block_count "${GHOSTTY}")" "0"
    assert_equal "$(_block_count "${TMUX_CONF}")" "0"
    assert_equal "$(cat "${GHOSTTY}")" "theme = dark"
    assert_equal "$(cat "${TMUX_CONF}")" "set -g mouse on"
    run cat "${CONFIG}"
    assert_line "auto-enter=no"
    assert_line "auto-enter.source=user"
}

@test "--auto-enter no with nothing managed says so for both files" {
    run "${SETUP}" --auto-enter no
    assert_success
    assert_line "[INFO] nothing to remove: ${GHOSTTY} (no managed block)"
    assert_line "[INFO] nothing to remove: ${TMUX_CONF} (no managed block)"
    assert [ ! -e "${GHOSTTY}" ]
    assert [ ! -e "${TMUX_CONF}" ]
}

# --- dry-run -----------------------------------------------------------------

@test "--dry-run logs every decision and what it would write, and writes nothing" {
    mkdir -p "${HOME}/.config/ghostty"
    run "${SETUP}" --dry-run --tmux host
    assert_success
    assert_line "[INFO] auto-enter: yes (default)"
    assert_line "[INFO] terminal: ghostty (default)"
    assert_line "[INFO] tmux: host (user)"
    assert_line "[INFO] dry-run: would write ${CONFIG}"
    assert_line "[INFO] dry-run: would write ${GHOSTTY} (managed block: ${CMD_HOST})"
    assert_line "[INFO] dry-run: would write ${TMUX_CONF} (managed block: ${TMUX_BODY})"
    assert [ ! -e "${CONFIG}" ]
    assert [ ! -e "${GHOSTTY}" ]
    assert [ ! -e "${TMUX_CONF}" ]
}

@test "--dry-run --auto-enter no reports what it would remove and removes nothing" {
    run "${SETUP}" --terminal ghostty
    assert_success
    run "${SETUP}" --dry-run --auto-enter no
    assert_success
    assert_line "[INFO] dry-run: would remove managed block from ${GHOSTTY}"
    assert_equal "$(_block_count "${GHOSTTY}")" "1"
    run cat "${CONFIG}"
    assert_line "auto-enter=yes"
}

# --- the script owns its CLI -------------------------------------------------

@test "--help exits 0, names every option, and touches nothing" {
    run "${SETUP}" --help
    assert_success
    assert_output --partial "--auto-enter"
    assert_output --partial "--terminal"
    assert_output --partial "--tmux"
    assert_output --partial "--box"
    assert_output --partial "--dry-run"
    assert_output --partial "--help"
    assert [ ! -e "${CONFIG}" ]
}

@test "-h is the same as --help" {
    run "${SETUP}" --help
    local _long="${output}"
    run "${SETUP}" -h
    assert_success
    assert_output "${_long}"
}

@test "an unknown option exits 2 with the documented message on stderr, nothing on stdout, nothing written" {
    local _out="${BATS_TEST_TMPDIR}/out" _err="${BATS_TEST_TMPDIR}/err"
    run bash -c '"$1" --bogus >"$2" 2>"$3"' _ "${SETUP}" "${_out}" "${_err}"
    assert_failure 2
    run cat "${_out}"
    assert_output ""
    run cat "${_err}"
    assert_output "setup.sh: unknown option '--bogus' (see --help)"
    assert [ ! -e "${CONFIG}" ]
}

@test "an unknown option is refused even when combined with --help: exit 2 and no usage" {
    run "${SETUP}" --help --bogus
    assert_failure 2
    assert_output "setup.sh: unknown option '--bogus' (see --help)"
    refute_output --partial "Usage:"
}

@test "an invalid value is refused with the expected choices, exit 2, nothing written" {
    run "${SETUP}" --auto-enter maybe
    assert_failure 2
    assert_output "setup.sh: invalid value 'maybe' for --auto-enter (expected yes|no) (see --help)"
    run "${SETUP}" --terminal kitty
    assert_failure 2
    assert_output "setup.sh: invalid value 'kitty' for --terminal (expected ghostty|none) (see --help)"
    run "${SETUP}" --tmux outside
    assert_failure 2
    assert_output "setup.sh: invalid value 'outside' for --tmux (expected inside|host) (see --help)"
    run "${SETUP}" --box 'bad name'
    assert_failure 2
    assert_output "setup.sh: invalid value 'bad name' for --box (expected a container name: [A-Za-z0-9][A-Za-z0-9_.-]*) (see --help)"
    assert [ ! -e "${CONFIG}" ]
}

@test "a value option without its value is refused, exit 2" {
    run "${SETUP}" --box
    assert_failure 2
    assert_output "setup.sh: --box requires a value (see --help)"
    assert [ ! -e "${CONFIG}" ]
}

@test "a corrupt stored value is refused with a clear error, exit 1, nothing rewritten" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'tmux=sideways\ntmux.source=user\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for tmux (expected inside|host)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'tmux=sideways\ntmux.source=user')"
}
