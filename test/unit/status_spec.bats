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
    assert_equal "${#lines[@]}" 7
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
