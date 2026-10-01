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
#     (auto-enter, terminal, box), and one line for the managed file (the
#     ghostty config) saying whether the worktool managed block is present
#     or absent. Since issue #179 there is no tmux decision and no
#     ~/.tmux.conf line: worktool never manages the host's tmux config.
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
#   - Issue #199: before that line, one `link: <box home>/<path> -> $HOME/<path>
#     (<state>)` line per user-config entry, under the box HOME #198
#     recorded - or one line saying none is recorded / it is the host HOME.
#   - Issue #198: the report ends with a `home: <path> (<source>)` line -
#     the box HOME `just box assemble` recorded - or `home: not recorded
#     (run: just box assemble)`. A recorded home that is not an absolute
#     path (or a bad home.source) is refused like any corrupt value.
#   - status never writes anything.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    STATUS="${REPO_ROOT}/script/box/status.sh"
    SETUP_SH="${REPO_ROOT}/script/box/setup.sh"
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

@test "without a state file: says so, shows the defaults as (default), the block absent" {
    run "${STATUS}"
    assert_success
    assert_line --index 0 "config: ${CONFIG} (not found - defaults shown; run: just box setup)"
    assert_line "auto-enter: yes (default)"
    assert_line "terminal: none (default)"
    assert_line "box: dev (default)"
    assert_line "ghostty: ${GHOSTTY} (managed block: absent)"
    assert_line "distrobox.conf: ${HOME}/.config/distrobox/distrobox.conf (managed block: absent)"
    refute_output --partial "tmux"
    assert_line "distrobox: ${DISTROBOX} (on PATH; no managed block records one)"
    assert_line "home: not recorded (run: just box assemble)"
    assert [ ! -e "${CONFIG}" ]
}

@test "without a state file the terminal default follows the ghostty config dir" {
    mkdir -p "${HOME}/.config/ghostty"
    run "${STATUS}"
    assert_success
    assert_line "terminal: ghostty (default)"
}

# --- with a state file -------------------------------------------------------

@test "prints every stored decision with its source and the block presence: nine lines, no tmux" {
    _write_config \
        'auto-enter=yes' 'auto-enter.source=default' \
        'terminal=ghostty' 'terminal.source=user' \
        'box=work' 'box.source=default'
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n%s\ncommand = true\n%s\n' "${BEGIN}" "${END}" >"${GHOSTTY}"
    run "${STATUS}"
    assert_success
    assert_line --index 0 "config: ${CONFIG}"
    assert_line --index 1 "auto-enter: yes (default)"
    assert_line --index 2 "terminal: ghostty (user)"
    assert_line --index 3 "box: work (default)"
    assert_line --index 4 "ghostty: ${GHOSTTY} (managed block: present)"
    assert_line --index 5 "distrobox.conf: ${HOME}/.config/distrobox/distrobox.conf (managed block: absent)"
    assert_line --index 6 "distrobox: ${DISTROBOX} (on PATH; no managed block records one)"
    assert_line "link: box HOME not recorded - user config not linked yet (run: just box assemble)"
    assert_line "home: not recorded (run: just box assemble)"
    assert_equal "${#lines[@]}" 9
}

# Issue #179: a state file an earlier worktool wrote still holds `tmux=`
# lines, and a ~/.tmux.conf may still hold its managed block. Neither is a
# decision any more: the key is not reported (nor refused), the file is
# not looked at.
@test "#179: a stored tmux line and a ~/.tmux.conf block are neither reported nor refused" {
    _write_config 'tmux=host' 'tmux.source=user' 'box=work' 'box.source=user'
    printf '%s\nset -g default-command x\n%s\n' "${BEGIN}" "${END}" >"${TMUX_CONF}"
    run "${STATUS}"
    assert_success
    assert_line "box: work (user)"
    refute_output --partial "tmux"
    assert_line "link: box HOME not recorded - user config not linked yet (run: just box assemble)"
    assert_line "home: not recorded (run: just box assemble)"
    assert_equal "${#lines[@]}" 9
}

# Issue #179 (codex round 4 on PR #232): the block in distrobox's own config
# that keeps a host tmux pane's TMUX out of the box is reported too.
@test "#179: the distrobox.conf block is reported present once setup.sh wrote it" {
    run "${SETUP_SH}" --terminal none
    assert_success
    run "${STATUS}"
    assert_success
    assert_line "distrobox.conf: ${HOME}/.config/distrobox/distrobox.conf (managed block: present)"
}

# --- #198: the box home assemble recorded ------------------------------------

@test "#198: the recorded box home is shown with its source, as the last line" {
    _write_config 'box=dev' 'box.source=default' 'home=/srv/my box' 'home.source=user'
    run "${STATUS}"
    assert_success
    assert_equal "${lines[${#lines[@]} - 1]}" "home: /srv/my box (user)"
    _write_config 'home=/h/dev-box' 'home.source=default'
    run "${STATUS}"
    assert_success
    assert_line "home: /h/dev-box (default)"
}

@test "#198: a recorded home that is not an absolute path is refused (exit 1, nothing on stdout)" {
    local _out="${BATS_TEST_TMPDIR}/out" _err="${BATS_TEST_TMPDIR}/err"
    _write_config 'home=dev-box' 'home.source=user'
    run bash -c '"$1" >"$2" 2>"$3"' _ "${STATUS}" "${_out}" "${_err}"
    assert_failure 1
    run cat "${_err}"
    assert_output "[ERROR] ${CONFIG}: invalid value 'dev-box' for home (expected an absolute path)"
    assert [ ! -s "${_out}" ]
    _write_config 'home=/srv/box' 'home.source=maybe'
    run "${STATUS}"
    assert_failure 1
    assert_output "[ERROR] ${CONFIG}: invalid value 'maybe' for home.source (expected default|user)"
}

@test "#198 r1: a lone home.source, or a root home, is refused like any corrupt value (exit 1)" {
    _write_config 'home.source=user'
    run "${STATUS}"
    assert_failure 1
    assert_output "[ERROR] ${CONFIG}: home.source without home (the two are recorded together)"
    _write_config 'home=/' 'home.source=user'
    run "${STATUS}"
    assert_failure 1
    assert_output "[ERROR] ${CONFIG}: invalid value '/' for home (expected a path other than the root directory)"
}

# --- #175: the report says whether the recorded distrobox still runs --------

# Write a managed block holding exactly the body $1 into file $2.
_write_block() {
    mkdir -p "$(dirname -- "$2")"
    printf '%s\n%s\n%s\n' "${BEGIN}" "$1" "${END}" >"$2"
}

@test "#175: a managed block that records a runnable distrobox is reported as runnable" {
    _write_block "command = '${DISTROBOX}' enter dev" "${GHOSTTY}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: ${DISTROBOX} (recorded in a managed block: runnable)"
}

@test "#175: a managed block whose distrobox path is gone is reported as NOT RUNNABLE with what to do" {
    _write_block "command = '/nowhere/bin/distrobox' enter dev" "${GHOSTTY}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: /nowhere/bin/distrobox (recorded in a managed block: NOT RUNNABLE - moved or removed; re-run: just box setup)"
}

# --- #180: legacy managed commands through the entry wrapper -------------------------
#
# Before issue #179 setup.sh wrote `'<enter.sh>' --distrobox '<distrobox>'
# --box <box> ...`: the distrobox is the value of --distrobox, not the first
# word, and must still be found and judged.

@test "#180: the distrobox recorded behind the enter.sh wrapper in the ghostty block is reported" {
    _write_block "command = '/repo/script/box/enter.sh' --distrobox '${DISTROBOX}' --box dev -- tmux new -A -s main" "${GHOSTTY}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: ${DISTROBOX} (recorded in a managed block: runnable)"
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
    _write_block "command = '${_path}' enter dev" "${GHOSTTY}"
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

# --- #199: the user-config links into the box HOME ---------------------------
# The box HOME is the one `just box assemble` recorded in the state file
# (issue #198, `home=`); none recorded means nothing is linked yet, and a
# recorded host HOME means there is nothing to link.

@test "#199: without a recorded box HOME one link line says nothing is linked yet" {
    run "${STATUS}"
    assert_success
    assert_line "link: box HOME not recorded - user config not linked yet (run: just box assemble)"
    run grep -c '^link: ' <<<"${output}"
    assert_output "1"
}

@test "#199: a recorded box HOME that is the host HOME reports the user config already in place" {
    _write_config "home=${HOME}/" 'home.source=user'
    run "${STATUS}"
    assert_success
    assert_line "link: the box HOME is the host HOME - user config already in place"
    run grep -c '^link: ' <<<"${output}"
    assert_output "1"
}

@test "#199: with a recorded box HOME every default link is reported, in list order, before the home line" {
    _write_config "home=${HOME}/dev-box" 'home.source=default'
    run "${STATUS}"
    assert_success
    assert_line --index 7 "link: ${HOME}/dev-box/.ssh -> ${HOME}/.ssh (missing source)"
    assert_line --index 8 "link: ${HOME}/dev-box/.gitconfig -> ${HOME}/.gitconfig (missing source)"
    assert_line --index 9 "link: ${HOME}/dev-box/.gnupg -> ${HOME}/.gnupg (missing source)"
    assert_line --index 10 "link: ${HOME}/dev-box/.config/gh -> ${HOME}/.config/gh (missing source)"
    assert_line --index 11 "home: ${HOME}/dev-box (default)"
    assert_equal "${#lines[@]}" 12
}

@test "#199: each link state is reported: linked, blocked by existing file, not linked yet" {
    local _box="${HOME}/dev-box"
    _write_config "home=${_box}" 'home.source=default'
    mkdir -p "${HOME}/.ssh" "${HOME}/.gnupg" "${_box}"
    printf '[user]\n' >"${HOME}/.gitconfig"
    ln -s "${HOME}/.ssh" "${_box}/.ssh"
    printf 'box-own\n' >"${_box}/.gitconfig"
    run "${STATUS}"
    assert_success
    assert_line "link: ${_box}/.ssh -> ${HOME}/.ssh (linked)"
    assert_line "link: ${_box}/.gitconfig -> ${HOME}/.gitconfig (blocked by existing file)"
    assert_line "link: ${_box}/.gnupg -> ${HOME}/.gnupg (not linked yet; run: just box assemble)"
    assert_line "link: ${_box}/.config/gh -> ${HOME}/.config/gh (missing source)"
    # status is read-only: nothing was linked or changed.
    [[ ! -e "${_box}/.gnupg" ]] || fail "status created a link"
    assert_equal "$(cat "${_box}/.gitconfig")" "box-own"
}

@test "#199: link= entries are reported under the recorded box HOME, not a manifest home=" {
    _write_config 'home=/srv/dev-home' 'home.source=user' 'link=~/.aws'
    run "${STATUS}"
    assert_success
    assert_line "link: /srv/dev-home/.ssh -> ${HOME}/.ssh (missing source)"
    assert_line "link: /srv/dev-home/.aws -> ${HOME}/.aws (missing source)"
}

# --- #161 (2): a corrupt state file is refused ------------------------------

@test "a corrupt stored value is refused with [ERROR] on stderr and exit 1, whatever its source" {
    local _out="${BATS_TEST_TMPDIR}/out" _err="${BATS_TEST_TMPDIR}/err"
    _write_config 'terminal=sideways' 'terminal.source=default'
    run bash -c '"$1" >"$2" 2>"$3"' _ "${STATUS}" "${_out}" "${_err}"
    assert_failure 1
    run cat "${_err}"
    assert_output "[ERROR] ${CONFIG}: invalid value 'sideways' for terminal (expected ghostty|none)"
    # Nothing on stdout: the check runs before any report line.
    assert [ ! -s "${_out}" ]
    _write_config 'terminal=sideways' 'terminal.source=user'
    run "${STATUS}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for terminal (expected ghostty|none)"
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
    _write_config 'terminal=' 'terminal.source=user'
    run bash -c '"$1" >"$2" 2>"$3"' _ "${STATUS}" "${_out}" "${_err}"
    assert_failure 1
    run cat "${_err}"
    assert_output "[ERROR] ${CONFIG}: invalid value '' for terminal (expected ghostty|none)"
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
    _write_config 'terminal=none' 'terminal=sideways' 'terminal.source=user'
    run "${STATUS}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for terminal (expected ghostty|none)"
    _write_config 'terminal=none' 'terminal.source=user' 'terminal.source=guess'
    run "${STATUS}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'guess' for terminal.source (expected default|user)"
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
