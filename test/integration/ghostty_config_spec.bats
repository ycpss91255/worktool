#!/usr/bin/env bats
# test/integration/ghostty_config_spec.bats - the managed block a real
# ghostty reads back (M3, issue #172; integration tier, GHOSTTY group)
#
# WHAT THIS PROVES
#   Layer 1 of the "open a window -> enter the box -> tmux/fish" chain, the
#   half that needs no display: what `just box setup` writes into
#   $XDG_CONFIG_HOME/ghostty/config is a config a REAL ghostty accepts and
#   resolves to exactly the command #5 promises.
#
#     - `ghostty +validate-config --config-file=<the written file>` exits 0:
#       the delivered managed block (marker lines included - they are `#`
#       comments to ghostty) parses.
#     - `ghostty +show-config` under XDG_CONFIG_HOME reports
#       `command = distrobox enter dev -- tmux new -A -s main` - the
#       EFFECTIVE value ghostty would run, not merely the text on disk.
#     - the other setup decisions travel the same way: `--tmux host` resolves
#       to `command = tmux new -A -s main`, `--box work` names that box.
#     - the assertion is not vacuous: after `--auto-enter no` removes the
#       block, ghostty reports no such command, and a config with a bogus
#       key is REFUSED by +validate-config. Both are the control cases that
#       would catch a +show-config / +validate-config that always says yes.
#
# WHY A SEPARATE GROUP
#   ghostty only exists in the Ubuntu 26.04 (resolute) archive, so this
#   spec runs in its own image (dockerfile/Dockerfile.ghostty) instead of
#   the alpine test image; `script/test/test.sh --integration` runs both
#   groups (the tier rules - required spec present and non-empty, at least
#   one case, no skip - apply to each). No display, no docker daemon and no
#   distrobox are needed here: layer 2 (a real window entering a real box)
#   is test/system/real_engine_spec.bats.
#
# NO HANG
#   Every ghostty call is wrapped in `timeout -k`; none of them opens a
#   window (`+validate-config` / `+show-config` are pure CLI actions), so
#   the budget below is generous on purpose and never reached in practice.

load "${BATS_TEST_DIRNAME}/../helper/common"

# Hard bound (seconds) on every ghostty CLI action; SIGKILL 5s later.
GHOSTTY_TIMEOUT=60

# What #5 / doc/enter.md promise the terminal runs, with the default box.
EXPECTED_COMMAND='distrobox enter dev -- tmux new -A -s main'

setup() {
    SETUP="${REPO_ROOT}/script/box/setup.sh"

    # Throwaway HOME / XDG_CONFIG_HOME: setup.sh writes there and ghostty
    # reads from there, so the real home is never touched. The ghostty dir
    # exists up front so setup.sh's terminal default detects ghostty.
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    XDG_CONFIG_HOME="${HOME}/.config"
    export XDG_CONFIG_HOME
    mkdir -p "${XDG_CONFIG_HOME}/ghostty"
    GHOSTTY_CONFIG="${XDG_CONFIG_HOME}/ghostty/config"
}

# Every ghostty call goes through here: a hard bound so a wedged ghostty
# can never hold a case open. Exit status is ghostty's (124 on timeout).
_ghostty() {
    timeout -k 5 "${GHOSTTY_TIMEOUT}" ghostty "$@"
}

# Echo the lines $2.. into the TAP stream (fd 3 is bats' original stdout;
# `# ` keeps the stream TAP-clean) and into the case's own output,
# prefixed with $1.
_log_lines() {
    local _tag="$1" _l
    shift
    for _l in "$@"; do
        printf '# %s: %s\n' "${_tag}" "${_l}" >&3
        echo "${_tag}: ${_l}"
    done
}

# --- preflight: this really is the ghostty group -----------------------------

@test "preflight: a real ghostty is on PATH and reports its version" {
    run _ghostty +version
    assert_success
    assert_line --regexp '^Ghostty [0-9]+\.[0-9]+'
    _log_lines ghostty "${lines[0]}"
}

# --- the delivered managed block is valid ghostty config ---------------------

@test "setup.sh writes a ghostty config that +validate-config accepts" {
    run "${SETUP}"
    assert_success
    assert [ -f "${GHOSTTY_CONFIG}" ]
    # --config-file exists for +validate-config (it does not for
    # +show-config, which is why the cases below go through XDG_CONFIG_HOME).
    run _ghostty +validate-config --config-file="${GHOSTTY_CONFIG}"
    assert_success
}

@test "+show-config resolves the delivered block to the promised enter command" {
    run "${SETUP}"
    assert_success
    run _ghostty +show-config
    assert_success
    assert_line "command = ${EXPECTED_COMMAND}"
    _log_lines effective "command = ${EXPECTED_COMMAND}"
}

@test "+show-config follows setup.sh --tmux host (tmux on the host, not in the box)" {
    run "${SETUP}" --tmux host
    assert_success
    run _ghostty +show-config
    assert_success
    assert_line 'command = tmux new -A -s main'
    refute_line --partial 'distrobox enter'
}

@test "+show-config follows setup.sh --box work (the box name reaches ghostty)" {
    run "${SETUP}" --box work
    assert_success
    run _ghostty +show-config
    assert_success
    assert_line 'command = distrobox enter work -- tmux new -A -s main'
}

# --- control cases: the two assertions above can fail ------------------------

@test "after setup.sh --auto-enter no there is no enter command left for ghostty to run" {
    run "${SETUP}"
    assert_success
    run _ghostty +show-config
    assert_line "command = ${EXPECTED_COMMAND}"
    run "${SETUP}" --auto-enter no
    assert_success
    run _ghostty +show-config
    assert_success
    refute_line "command = ${EXPECTED_COMMAND}"
    refute_line --partial 'distrobox enter'
}

@test "+validate-config refuses a config ghostty cannot parse (the check bites)" {
    printf 'not-a-ghostty-key = 1\n' >"${GHOSTTY_CONFIG}"
    run _ghostty +validate-config --config-file="${GHOSTTY_CONFIG}"
    assert_failure
    # ghostty's own words, so a `ghostty` that is merely missing (exit 127)
    # can never satisfy this case.
    assert_output --partial 'not-a-ghostty-key: unknown field'
    _log_lines refused "${lines[@]}"
}
