#!/usr/bin/env bats
# test/unit/status_spec.bats - script/box/status.sh: show the auto-enter
# decisions in force, their sources, and the managed blocks (M3, issue #21)
#
# Written test-first (RED) before the script exists, then the script is
# implemented to pass (GREEN).
#
# Contract under test:
#   - status prints, on STDOUT (machine-readable, no log tags), the state
#     file path, one `<key>: <value> (<source>)` line per decision
#     (auto-enter, terminal, tmux, box), and one line per managed file
#     (ghostty config, ~/.tmux.conf) saying whether the worktool managed
#     block is present or absent.
#   - Without a state file it says so and shows the defaults (source
#     `default`), so the report is never empty.
#   - A key missing from the state file falls back to its default.
#   - Every path comes from HOME / XDG_CONFIG_HOME (throwaway HOME per case;
#     the real home is never read).
#   - Since issue #175 the report ends with a `distrobox: ...` line: the
#     managed command now names an ABSOLUTE distrobox path, so the report
#     has to say whether that path is still runnable. That line is the
#     readable error when distrobox is moved or removed after setup - the
#     alternative is a terminal window that flashes `not found` and closes.
#   - The script owns its CLI: --help / -h exit 0; an unknown option is
#     refused with `status.sh: unknown option '<x>' (see --help)`, exit 2.
#   - status never writes anything.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    STATUS="${REPO_ROOT}/script/box/status.sh"
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CONFIG_HOME
    mkdir -p "${HOME}"
    CONFIG="${HOME}/.config/worktool/config"
    GHOSTTY="${HOME}/.config/ghostty/config"
    TMUX_CONF="${HOME}/.tmux.conf"
    BEGIN="# BEGIN worktool managed block (just box setup; do not edit)"
    END="# END worktool managed block"

    # Issue #175: a distrobox of the case's own, in a directory no test
    # image has on PATH, so the `distrobox: ...` report line is the same
    # whatever the image ships.
    DBX_DIR="${BATS_TEST_TMPDIR}/local/bin"
    DISTROBOX="${DBX_DIR}/distrobox"
    mkdir -p "${DBX_DIR}"
    printf '#!/bin/sh\nexit 0\n' >"${DISTROBOX}"
    chmod +x "${DISTROBOX}"
    PATH="${DBX_DIR}:${PATH}"
    export PATH
}

# Write a state file at $CONFIG with the given key=value lines.
_write_config() {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf '%s\n' "$@" >"${CONFIG}"
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# --- no state file -----------------------------------------------------------

@test "without a state file: says so, shows the defaults as (default), both blocks absent" {
    run "${STATUS}"
    assert_success
    assert_line --index 0 "config: ${CONFIG} (not found - defaults shown; run: just box setup)"
    assert_line "auto-enter: yes (default)"
    assert_line "terminal: none (default)"
    assert_line "tmux: inside (default)"
    assert_line "box: dev (default)"
    assert_line "ghostty: ${GHOSTTY} (managed block: absent)"
    assert_line "tmux.conf: ${TMUX_CONF} (managed block: absent)"
    assert_line "distrobox: ${DISTROBOX} (on PATH; no managed block records one)"
    assert [ ! -e "${CONFIG}" ]
}

@test "without a state file the terminal default follows the ghostty config dir" {
    mkdir -p "${HOME}/.config/ghostty"
    run "${STATUS}"
    assert_success
    assert_line "terminal: ghostty (default)"
}

# --- with a state file -------------------------------------------------------

@test "prints every stored decision with its source and the block presence per file" {
    _write_config \
        'auto-enter=yes' 'auto-enter.source=default' \
        'terminal=ghostty' 'terminal.source=user' \
        'tmux=host' 'tmux.source=user' \
        'box=work' 'box.source=default'
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n%s\ncommand = tmux new -A -s main\n%s\n' "${BEGIN}" "${END}" >"${GHOSTTY}"
    printf 'set -g mouse on\n' >"${TMUX_CONF}"
    run "${STATUS}"
    assert_success
    assert_line --index 0 "config: ${CONFIG}"
    assert_line --index 1 "auto-enter: yes (default)"
    assert_line --index 2 "terminal: ghostty (user)"
    assert_line --index 3 "tmux: host (user)"
    assert_line --index 4 "box: work (default)"
    assert_line --index 5 "ghostty: ${GHOSTTY} (managed block: present)"
    assert_line --index 6 "tmux.conf: ${TMUX_CONF} (managed block: absent)"
    assert_line --index 7 "distrobox: ${DISTROBOX} (on PATH; no managed block records one)"
    assert_equal "${#lines[@]}" 8
}

# --- #175: the report says whether the recorded distrobox still runs --------

# Write a managed block holding exactly the body $1 into file $2.
_write_block() {
    mkdir -p "$(dirname -- "$2")"
    printf '%s\n%s\n%s\n' "${BEGIN}" "$1" "${END}" >"$2"
}

@test "#175: a managed block that records a runnable distrobox is reported as runnable" {
    _write_block "command = '${DISTROBOX}' enter dev -- tmux new -A -s main" "${GHOSTTY}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: ${DISTROBOX} (recorded in a managed block: runnable)"
}

@test "#175: a managed block whose distrobox path is gone is reported as NOT RUNNABLE with what to do" {
    _write_block "command = '/nowhere/bin/distrobox' enter dev -- tmux new -A -s main" "${GHOSTTY}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: /nowhere/bin/distrobox (recorded in a managed block: NOT RUNNABLE - moved or removed; re-run: just box setup)"
}

@test "#175: the distrobox recorded in the ~/.tmux.conf default-command is reported too" {
    _write_block "set -g default-command '\"/nowhere/bin/distrobox\" enter dev'" "${TMUX_CONF}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: /nowhere/bin/distrobox (recorded in a managed block: NOT RUNNABLE - moved or removed; re-run: just box setup)"
}

# --- #180: the managed command runs the entry wrapper -------------------------
#
# Since issue #180 setup.sh writes `'<enter.sh>' --distrobox '<distrobox>'
# --box <box> ...`: the distrobox is the value of --distrobox, not the first
# word, and must still be found and judged.

@test "#180: the distrobox recorded behind the enter.sh wrapper in the ghostty block is reported" {
    _write_block "command = '/repo/script/box/enter.sh' --distrobox '${DISTROBOX}' --box dev -- tmux new -A -s main" "${GHOSTTY}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: ${DISTROBOX} (recorded in a managed block: runnable)"
}

@test "#180: the wrapper form in ~/.tmux.conf is decoded through both quoting layers" {
    local _d='$' _path
    _path="/nowhere/my ${_d}dir/distrobox"
    _write_block "set -g default-command '\"/my repo/script/box/enter.sh\" --distrobox \"/nowhere/my \\${_d}dir/distrobox\" --box dev'" "${TMUX_CONF}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: ${_path} (recorded in a managed block: NOT RUNNABLE - moved or removed; re-run: just box setup)"
}

@test "#180: a wrapper body without --distrobox records no distrobox (the PATH one is reported)" {
    _write_block "command = '/repo/script/box/enter.sh' --box dev" "${GHOSTTY}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: ${DISTROBOX} (on PATH; no managed block records one)"
}

# --- #175 round 1: the recorded path is a QUOTED shell word ------------------
#
# The literal dollar below is built from a variable so the metacharacter is
# unmistakably data, in the test as well as in the block under test.

@test "#175r1: a recorded path holding spaces and metacharacters is decoded whole, not split at the first space" {
    local _d='$' _path
    _path="/nowhere/my ${_d}dir/distrobox"
    _write_block "command = '${_path}' enter dev -- tmux new -A -s main" "${GHOSTTY}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: ${_path} (recorded in a managed block: NOT RUNNABLE - moved or removed; re-run: just box setup)"
}

@test "#175r1: a recorded tmux default-command path is decoded through BOTH quoting layers" {
    local _d='$' _path
    _path="/nowhere/my ${_d}dir/distrobox"
    # tmux owns the outer single quotes; the shell word inside is
    # double-quoted, so the dollar arrives backslash-escaped.
    _write_block "set -g default-command '\"/nowhere/my \\${_d}dir/distrobox\" enter dev'" "${TMUX_CONF}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: ${_path} (recorded in a managed block: NOT RUNNABLE - moved or removed; re-run: just box setup)"
}

# An UNQUOTED absolute path is what the first attempt at issue #175 wrote;
# a block a user still has must keep being readable.
@test "#175r1: an unquoted absolute path left by an earlier setup is still decoded" {
    _write_block "command = /nowhere/bin/distrobox enter dev -- tmux new -A -s main" "${GHOSTTY}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: /nowhere/bin/distrobox (recorded in a managed block: NOT RUNNABLE - moved or removed; re-run: just box setup)"
}

@test "#175: a managed block that still records the BARE name is called out as the shape the desktop cannot run" {
    mkdir -p "${HOME}/.config/ghostty"
    printf '%s\ncommand = distrobox enter dev -- tmux new -A -s main\n%s\n' \
        "${BEGIN}" "${END}" >"${GHOSTTY}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: distrobox (recorded in a managed block: a bare name, not an absolute path - a terminal launched from the desktop may not find it; re-run: just box setup)"
}

@test "#175: with no distrobox on PATH and no managed block the report says so instead of staying silent" {
    PATH="/usr/bin:/bin" run "${STATUS}"
    assert_success
    assert_line "distrobox: not found on PATH (install distrobox, then re-run: just box setup)"
}

@test "a key missing from the state file falls back to its default" {
    _write_config 'box=work' 'box.source=user'
    run "${STATUS}"
    assert_success
    assert_line "auto-enter: yes (default)"
    assert_line "box: work (user)"
}

@test "XDG_CONFIG_HOME relocates the state file and the ghostty config in the report" {
    local _xdg="${BATS_TEST_TMPDIR}/xdg"
    mkdir -p "${_xdg}/worktool" "${_xdg}/ghostty"
    printf 'terminal=none\nterminal.source=user\n' >"${_xdg}/worktool/config"
    printf '%s\ncommand = distrobox enter dev -- tmux new -A -s main\n%s\n' \
        "${BEGIN}" "${END}" >"${_xdg}/ghostty/config"
    XDG_CONFIG_HOME="${_xdg}" run "${STATUS}"
    assert_success
    assert_line --index 0 "config: ${_xdg}/worktool/config"
    assert_line "terminal: none (user)"
    assert_line "ghostty: ${_xdg}/ghostty/config (managed block: present)"
}

@test "the report goes to stdout and nothing to stderr" {
    local _out="${BATS_TEST_TMPDIR}/out" _err="${BATS_TEST_TMPDIR}/err"
    run bash -c '"$1" >"$2" 2>"$3"' _ "${STATUS}" "${_out}" "${_err}"
    assert_success
    run cat "${_err}"
    assert_output ""
    run cat "${_out}"
    assert_line "auto-enter: yes (default)"
}

# --- #161 (2): a corrupt state file is refused ------------------------------

@test "a corrupt stored value is refused with [ERROR] on stderr and exit 1, whatever its source" {
    local _out="${BATS_TEST_TMPDIR}/out" _err="${BATS_TEST_TMPDIR}/err"
    _write_config 'tmux=sideways' 'tmux.source=default'
    run bash -c '"$1" >"$2" 2>"$3"' _ "${STATUS}" "${_out}" "${_err}"
    assert_failure 1
    run cat "${_err}"
    assert_output "[ERROR] ${CONFIG}: invalid value 'sideways' for tmux (expected inside|host)"
    # Nothing on stdout: the check runs before any report line.
    assert [ ! -s "${_out}" ]
    _write_config 'tmux=sideways' 'tmux.source=user'
    run "${STATUS}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for tmux (expected inside|host)"
}

@test "a corrupt stored source is refused with exit 1" {
    _write_config 'box=work' 'box.source=guess'
    run "${STATUS}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'guess' for box.source (expected default|user)"
}

# A present key with an empty value is a stored value, not an absent key.
@test "an empty stored value is refused with exit 1, nothing on stdout" {
    local _out="${BATS_TEST_TMPDIR}/out" _err="${BATS_TEST_TMPDIR}/err"
    _write_config 'tmux=' 'tmux.source=user'
    run bash -c '"$1" >"$2" 2>"$3"' _ "${STATUS}" "${_out}" "${_err}"
    assert_failure 1
    run cat "${_err}"
    assert_output "[ERROR] ${CONFIG}: invalid value '' for tmux (expected inside|host)"
    assert [ ! -s "${_out}" ]
    _write_config 'box=' 'box.source=user'
    run "${STATUS}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value '' for box (expected a container name: [A-Za-z0-9][A-Za-z0-9_.-]*)"
    _write_config 'box=work' 'box.source='
    run "${STATUS}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value '' for box.source (expected default|user)"
}

# Every line is validated: a corrupt duplicate behind a valid first line is
# refused too (the report would otherwise show the first line and hide it).
@test "a corrupt duplicate key is refused even when its first occurrence is valid" {
    _write_config 'tmux=host' 'tmux=sideways' 'tmux.source=user'
    run "${STATUS}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for tmux (expected inside|host)"
    _write_config 'tmux=host' 'tmux.source=user' 'tmux.source=guess'
    run "${STATUS}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'guess' for tmux.source (expected default|user)"
}

# --- the script owns its CLI -------------------------------------------------

@test "--help exits 0 and -h is the same" {
    run "${STATUS}" --help
    assert_success
    assert_output --partial "Usage: status.sh"
    assert_output --partial "--help"
    local _long="${output}"
    run "${STATUS}" -h
    assert_success
    assert_output "${_long}"
}

@test "an unknown option exits 2 with the documented message on stderr, nothing on stdout" {
    local _out="${BATS_TEST_TMPDIR}/out" _err="${BATS_TEST_TMPDIR}/err"
    run bash -c '"$1" --bogus >"$2" 2>"$3"' _ "${STATUS}" "${_out}" "${_err}"
    assert_failure 2
    run cat "${_out}"
    assert_output ""
    run cat "${_err}"
    assert_output "status.sh: unknown option '--bogus' (see --help)"
}

@test "an unknown option is refused even when combined with --help" {
    run "${STATUS}" --help --bogus
    assert_failure 2
    assert_output "status.sh: unknown option '--bogus' (see --help)"
    refute_output --partial "Usage:"
}

# --- errexit (issue #195) ----------------------------------------------------

@test "status.sh runs under set -euo pipefail (one set line, errexit included)" {
    run grep -E '^set -[a-z]+( pipefail)?$' "${STATUS}"
    assert_success
    assert_output 'set -euo pipefail'
}
