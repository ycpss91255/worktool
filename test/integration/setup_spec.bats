#!/usr/bin/env bats
# test/integration/setup_spec.bats - setup -> status round-trip (M3, issue #21)
#
# Proves the two real scripts cooperate through the ONE state file and the
# managed blocks: what `setup.sh` decides and writes is exactly what
# `status.sh` reports back, through every transition a user makes (enable
# with the tmux-on-host variant, switch tmux inside, disable, dry-run).
# Runs against a throwaway HOME; the real home is never touched, and no
# distrobox / ghostty / tmux binary is needed (only files are managed).

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    SETUP="${REPO_ROOT}/script/box/setup.sh"
    STATUS="${REPO_ROOT}/script/box/status.sh"
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CONFIG_HOME
    mkdir -p "${HOME}/.config/ghostty"
    CONFIG="${HOME}/.config/worktool/config"
    GHOSTTY="${HOME}/.config/ghostty/config"
    TMUX_CONF="${HOME}/.tmux.conf"
}

@test "setup (tmux host) then status: status reports the stored decisions, sources and both blocks present" {
    run "${SETUP}" --tmux host --box work
    assert_success
    run "${STATUS}"
    assert_success
    assert_line --index 0 "config: ${CONFIG}"
    assert_line "auto-enter: yes (default)"
    assert_line "terminal: ghostty (default)"
    assert_line "tmux: host (user)"
    assert_line "box: work (user)"
    assert_line "ghostty: ${GHOSTTY} (managed block: present)"
    assert_line "tmux.conf: ${TMUX_CONF} (managed block: present)"
}

@test "setup --tmux inside after host: status shows the tmux.conf block gone, ghostty still present" {
    run "${SETUP}" --tmux host
    assert_success
    run "${SETUP}" --tmux inside
    assert_success
    run "${STATUS}"
    assert_success
    assert_line "tmux: inside (user)"
    assert_line "ghostty: ${GHOSTTY} (managed block: present)"
    assert_line "tmux.conf: ${TMUX_CONF} (managed block: absent)"
    run grep -F 'command = distrobox enter dev -- tmux new -A -s main' "${GHOSTTY}"
    assert_success
}

@test "setup --auto-enter no then status: no (user) and both blocks absent" {
    run "${SETUP}" --tmux host
    assert_success
    run "${SETUP}" --auto-enter no
    assert_success
    run "${STATUS}"
    assert_success
    assert_line "auto-enter: no (user)"
    assert_line "ghostty: ${GHOSTTY} (managed block: absent)"
    assert_line "tmux.conf: ${TMUX_CONF} (managed block: absent)"
}

@test "setup --dry-run then status: nothing was stored, status still shows the defaults" {
    run "${SETUP}" --dry-run --tmux host
    assert_success
    run "${STATUS}"
    assert_success
    assert_line --index 0 "config: ${CONFIG} (not found - defaults shown; run: just box setup)"
    assert_line "tmux: inside (default)"
    assert_line "ghostty: ${GHOSTTY} (managed block: absent)"
}

@test "the setup log and the status report agree on every decision line" {
    run "${SETUP}" --terminal ghostty --box work
    assert_success
    local _setup_lines
    _setup_lines="$(printf '%s\n' "${lines[@]}" | sed -nE 's/^\[INFO\] ((auto-enter|terminal|tmux|box): .*)$/\1/p')"
    run "${STATUS}"
    assert_success
    local _status_lines
    _status_lines="$(printf '%s\n' "${lines[@]}" | grep -E '^(auto-enter|terminal|tmux|box): ')"
    assert_equal "${_status_lines}" "${_setup_lines}"
}
