#!/usr/bin/env bats
# test/integration/setup_spec.bats - setup -> status round-trip (M3, issue #21)
#
# Proves the two real scripts cooperate through the ONE state file and the
# managed blocks: what `setup.sh` decides and writes is exactly what
# `status.sh` reports back, through every transition a user makes (enable
# with another box, disable, dry-run). Since issue #179 there is no tmux
# decision: the managed command is `'<distrobox>' enter <box>` and
# ~/.tmux.conf is never touched. Runs against a throwaway HOME; the real
# home is never touched, and no distrobox / ghostty / tmux binary is needed
# (only files are managed).

load "${BATS_TEST_DIRNAME}/../helper/common"

# `run -127` (a control case asserting `command not found`) is a flagged
# run, which bats only accepts once the minimum version is declared.
bats_require_minimum_version 1.5.0

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

    # Issue #175: the managed command names the ABSOLUTE path of the
    # distrobox setup.sh resolved. Each case installs its own, under a
    # directory no test image has on PATH, so the expectation does not
    # depend on where the image happens to put distrobox.
    DBX_DIR="${BATS_TEST_TMPDIR}/local/bin"
    DISTROBOX="${DBX_DIR}/distrobox"
    mkdir -p "${DBX_DIR}"
    cat >"${DISTROBOX}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$0.log"
EOF
    chmod +x "${DISTROBOX}"
    PATH="${DBX_DIR}:${PATH}"
    export PATH

}

@test "setup then status: status reports the stored decisions, sources and the ghostty block present, no tmux line" {
    run "${SETUP}" --box work
    assert_success
    run "${STATUS}"
    assert_success
    assert_line --index 0 "config: ${CONFIG}"
    assert_line "auto-enter: yes (default)"
    assert_line "terminal: ghostty (default)"
    assert_line "box: work (user)"
    assert_line "ghostty: ${GHOSTTY} (managed block: present)"
    assert_line "distrobox.conf: ${HOME}/.config/distrobox/distrobox.conf (managed block: present)"
    refute_output --partial "tmux"
    run grep -xF "command = '${DISTROBOX}' enter work" "${GHOSTTY}"
    assert_success
    assert [ ! -e "${TMUX_CONF}" ]
}

@test "setup --auto-enter no then status: no (user) and the block absent" {
    run "${SETUP}"
    assert_success
    run "${SETUP}" --auto-enter no
    assert_success
    run "${STATUS}"
    assert_success
    assert_line "auto-enter: no (user)"
    assert_line "ghostty: ${GHOSTTY} (managed block: absent)"
    # #179: the box's tmux isolation is not a terminal choice.
    assert_line "distrobox.conf: ${HOME}/.config/distrobox/distrobox.conf (managed block: present)"
}

@test "setup --dry-run then status: nothing was stored, status still shows the defaults" {
    run "${SETUP}" --dry-run --box work
    assert_success
    run "${STATUS}"
    assert_success
    assert_line --index 0 "config: ${CONFIG} (not found - defaults shown; run: just box setup)"
    assert_line "box: dev (default)"
    assert_line "ghostty: ${GHOSTTY} (managed block: absent)"
}

@test "the setup log and the status report agree on every decision line" {
    run "${SETUP}" --terminal ghostty --box work
    assert_success
    local _setup_lines
    _setup_lines="$(printf '%s\n' "${lines[@]}" | sed -nE 's/^\[INFO\] ((auto-enter|terminal|box): .*)$/\1/p')"
    run "${STATUS}"
    assert_success
    local _status_lines
    _status_lines="$(printf '%s\n' "${lines[@]}" | grep -E '^(auto-enter|terminal|box): ')"
    assert_equal "${_status_lines}" "${_setup_lines}"
}

# --- #161 -------------------------------------------------------------------

@test "setup --terminal none then status: none (user) stored, the block absent" {
    run "${SETUP}" --terminal none
    assert_success
    run "${STATUS}"
    assert_success
    assert_line "terminal: none (user)"
    assert_line "ghostty: ${GHOSTTY} (managed block: absent)"
}

@test "a state file setup wrote and a user then corrupted is refused by both scripts, and setup leaves it as is" {
    run "${SETUP}" --terminal none
    assert_success
    sed -i 's/^terminal=none$/terminal=sideways/' "${CONFIG}"
    local _before
    _before="$(cat "${CONFIG}")"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for terminal (expected ghostty|none)"
    run "${STATUS}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for terminal (expected ghostty|none)"
    assert_equal "$(cat "${CONFIG}")" "${_before}"
}

# --- #175 ---------------------------------------------------------------
#
# The M3 real-machine acceptance failed with `/bin/sh: 1: distrobox: not
# found`: a terminal started from the GNOME desktop inherits the systemd
# user manager's PATH, which does not hold ~/.local/bin, and the managed
# command was the bare name. These cases run the command setup.sh really
# wrote, in that reduced environment.

@test "#175: the command setup wrote runs under the reduced PATH of a desktop session (the bare name does not)" {
    run "${SETUP}" --terminal ghostty
    assert_success
    local _cmd
    _cmd="$(sed -n 's/^command = //p' "${GHOSTTY}")"
    assert_equal "${_cmd}" "'${DISTROBOX}' enter dev"

    # Control: that environment really cannot reach this distrobox by name,
    # so the case below cannot pass by accident.
    run -127 env -i PATH=/usr/bin:/bin HOME="${HOME}" /bin/sh -c \
        'distrobox enter dev'
    assert_failure 127
    assert_output --partial 'not found'

    # What ghostty runs: `/bin/sh -c "<the managed command>"`.
    run env -i PATH=/usr/bin:/bin HOME="${HOME}" /bin/sh -c "${_cmd}"
    assert_success
    run cat "${DISTROBOX}.log"
    assert_line "enter dev"
}

@test "#175: status reports the distrobox the managed block records, and flags it once it is gone" {
    run "${SETUP}" --terminal ghostty
    assert_success
    run "${STATUS}"
    assert_success
    assert_line "distrobox: ${DISTROBOX} (recorded in a managed block: runnable)"

    # The path setup resolved stops working (distrobox moved or removed):
    # the report is the readable error, not a window that flashes and dies.
    rm -f "${DISTROBOX}"
    run "${STATUS}"
    assert_success
    assert_line "distrobox: ${DISTROBOX} (recorded in a managed block: NOT RUNNABLE - moved or removed; re-run: just box setup)"
}
