#!/usr/bin/env bats
# test/system/real_enter_env_spec.bats - what the REAL distrobox-enter hands
# the box, system tier, shim group (issue #179)
#
# WHAT THIS PROVES
#   `distrobox enter` copies the caller's environment into the box: the
#   pinned distrobox-enter (1.8.2.5) turns `printenv` into one `--env=` per
#   variable of the `exec` request, skipping only a fixed list (HOME, PATH,
#   PWD, ...). Entered from a HOST tmux pane, that request carries TMUX -
#   the host server's socket, on the /tmp the box shares with the host - and
#   tmux in the box prefers it over the box's TMUX_TMPDIR, whatever binary
#   runs. The fix is the environment: the DELIVERED `just box setup`
#   (script/box/setup.sh) keeps a managed block in distrobox's own user
#   config, which distrobox-enter sources before it builds the request, and
#   that block drops TMUX / TMUX_PANE for the box. These cases run the REAL
#   distrobox-enter in its own dry-run mode (`--dry-run` prints the exact
#   engine command and runs nothing, so no engine is needed) and read the
#   request it would send:
#     - control: with no block, TMUX and TMUX_PANE ARE in the request (the
#       leak is real in the pinned version, so the other cases can fail);
#     - after setup.sh, for every entry shape (bare enter, `-- <cmd>`,
#       `-- <real tmux>`, `--name`, a login shell), neither is in the
#       request, while the rest of the caller's environment still is;
#     - another box keeps upstream behaviour (the block names the box).
#   A real box, a real host tmux server and every tmux invocation are
#   test/system/real_engine_spec.bats (system-real).

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    SETUP="${REPO_ROOT}/script/box/setup.sh"
    # Hermetic distrobox environment: a fresh HOME (no ~/.distroboxrc, no
    # distrobox.conf), docker selected by name (dry-run never runs it).
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    unset XDG_CONFIG_HOME
    export DBX_CONTAINER_MANAGER=docker
    # distrobox-enter runs under `set -o nounset` and reads USER.
    export USER="${USER:-root}"
    HOST_TMUX="/tmp/tmux-$(id -u)/default,4242,0"
}

# The `exec` request the real distrobox-enter would send for `distrobox
# enter --dry-run <args>`, entered from a host tmux pane (TMUX, TMUX_PANE)
# with one ordinary variable of the caller's own (WORKTOOL_PROBE).
_request() {
    TMUX="${HOST_TMUX}" TMUX_PANE="%3" WORKTOOL_PROBE=kept \
        distrobox enter --dry-run "$@" </dev/null
}

@test "control: with no distrobox.conf block, the pinned distrobox-enter hands the box the host pane's TMUX and TMUX_PANE" {
    [[ -n "${DISTROBOX_VERSION:-}" ]] \
        || fail "DISTROBOX_VERSION not set - this tier runs inside the test image only"
    run _request dev -- /usr/bin/tmux ls
    assert_success
    assert_line --partial "--env=TMUX=${HOST_TMUX}"
    assert_line --partial "--env=TMUX_PANE=%3"
    assert_line --partial "--env=WORKTOOL_PROBE=kept"
}

@test "the delivered setup.sh writes the distrobox.conf block distrobox-enter reads, whatever the terminal decision" {
    run "${SETUP}" --terminal none --box dev
    assert_success
    assert [ -f "${HOME}/.config/distrobox/distrobox.conf" ]
    run grep -c "unset TMUX TMUX_PANE" "${HOME}/.config/distrobox/distrobox.conf"
    assert_output "1"
}

# Every entry shape into the box (the managed terminal command is `enter
# dev`, a user types `enter dev` or `enter dev -- <cmd>`, the real tmux can
# be named directly, a login shell can be asked for): none carries the host
# pane's TMUX / TMUX_PANE into the request, and the caller's other
# variables still travel.
@test "after setup.sh, no entry shape into the box carries the host pane's TMUX / TMUX_PANE (entry-shape table)" {
    run "${SETUP}" --terminal none --box dev
    assert_success
    local _row
    local -a _args
    local -a _table=(
        "dev"
        "dev -- tmux ls"
        "dev -- tmux new -A -s main"
        "dev -- /usr/bin/tmux attach"
        "dev -- sh -c tmux"
        "dev -- sh -l"
        "dev -- fish -l"
        "--name dev -- /usr/bin/tmux ls"
        "-n dev -e /usr/bin/tmux"
    )
    for _row in "${_table[@]}"; do
        read -r -a _args <<<"${_row}"
        run _request "${_args[@]}"
        assert_success
        refute_line --partial "--env=TMUX="
        refute_line --partial "--env=TMUX_PANE="
        assert_line --partial "--env=WORKTOOL_PROBE=kept"
    done
}

@test "after setup.sh, another box keeps upstream behaviour: the block names the box" {
    run "${SETUP}" --terminal none --box dev
    assert_success
    run _request other -- tmux ls
    assert_success
    assert_line --partial "--env=TMUX=${HOST_TMUX}"
}
