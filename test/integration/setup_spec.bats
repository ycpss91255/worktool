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
    # `~/.tmux.conf` is the user's file, and this transition is the one
    # place the tmux-inside branch of _apply_ghostty removes a block from
    # it. `managed block: absent` is equally true of a file the removal
    # EMPTIED, so the user's own lines are seeded first and compared
    # afterwards: that comparison is the only thing here that tells
    # "stripped the block" apart from "truncated the file".
    local _user_lines='# user tmux config
set -g history-limit 12345
set -g mouse on'
    printf '%s\n' "${_user_lines}" >"${TMUX_CONF}"

    run "${SETUP}" --tmux host
    assert_success
    # The removal is vacuous unless a block was really written first.
    run grep -cxF '# BEGIN worktool managed block (just box setup; do not edit)' "${TMUX_CONF}"
    assert_success
    assert_output "1"

    run "${SETUP}" --tmux inside
    assert_success
    assert_line "[INFO] removed: ${TMUX_CONF} (managed block: set -g default-command '\"${DISTROBOX}\" enter dev')"
    run "${STATUS}"
    assert_success
    assert_line "tmux: inside (user)"
    assert_line "ghostty: ${GHOSTTY} (managed block: present)"
    assert_line "tmux.conf: ${TMUX_CONF} (managed block: absent)"
    run grep -F "command = '${DISTROBOX}' enter dev -- tmux new -A -s main" "${GHOSTTY}"
    assert_success

    # What is left of ~/.tmux.conf is exactly what the user brought to it.
    run cat "${TMUX_CONF}"
    assert_success
    assert_output "${_user_lines}"
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

# --- #161 -------------------------------------------------------------------

@test "setup --terminal none --tmux host then status: tmux host (user) stored, both blocks absent" {
    run "${SETUP}" --terminal none --tmux host
    assert_success
    run "${STATUS}"
    assert_success
    assert_line "terminal: none (user)"
    assert_line "tmux: host (user)"
    assert_line "ghostty: ${GHOSTTY} (managed block: absent)"
    assert_line "tmux.conf: ${TMUX_CONF} (managed block: absent)"
    assert [ ! -e "${TMUX_CONF}" ]
}

@test "a state file setup wrote and a user then corrupted is refused by both scripts, and setup leaves it as is" {
    run "${SETUP}" --tmux host
    assert_success
    sed -i 's/^tmux=host$/tmux=sideways/' "${CONFIG}"
    local _before
    _before="$(cat "${CONFIG}")"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for tmux (expected inside|host)"
    run "${STATUS}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for tmux (expected inside|host)"
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
    assert_equal "${_cmd}" "'${DISTROBOX}' enter dev -- tmux new -A -s main"

    # Control: that environment really cannot reach this distrobox by name,
    # so the case below cannot pass by accident.
    run -127 env -i PATH=/usr/bin:/bin HOME="${HOME}" /bin/sh -c \
        'distrobox enter dev -- tmux new -A -s main'
    assert_failure 127
    assert_output --partial 'not found'

    # What ghostty runs: `/bin/sh -c "<the managed command>"`.
    run env -i PATH=/usr/bin:/bin HOME="${HOME}" /bin/sh -c "${_cmd}"
    assert_success
    run cat "${DISTROBOX}.log"
    assert_line "enter dev -- tmux new -A -s main"
}

@test "#175: the tmux host default-command also runs under the reduced PATH of a desktop session" {
    run "${SETUP}" --terminal ghostty --tmux host
    assert_success
    local _cmd
    _cmd="$(sed -n "s/^set -g default-command '\\(.*\\)'\$/\\1/p" "${TMUX_CONF}")"
    assert_equal "${_cmd}" "\"${DISTROBOX}\" enter dev"
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
