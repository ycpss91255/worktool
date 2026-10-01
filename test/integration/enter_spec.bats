#!/usr/bin/env bats
# test/integration/enter_spec.bats - the first-launch entry path end to end
# (M3, issue #180)
#
# The unit spec pins enter.sh on its own; this spec proves the pieces are
# wired together the way a user meets them:
#   - `just box enter` (the real box justfile -> the real enter.sh) on a box
#     that was never started prints the first-launch notice, keeps printing
#     progress, saves the host log and hands over to distrobox;
#   - the command `just box setup` writes into the ghostty profile, run the
#     way ghostty runs it (`/bin/sh -c` under a desktop session's reduced
#     PATH, where only the fake engine is added), enters the box directly
#     without starting tmux (issue #179).
#
# The engine and distrobox are fakes (test/helper/enter_fake.bash); HOME is
# a throwaway directory.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/enter_fake"

setup() {
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CONFIG_HOME XDG_CACHE_HOME WORKTOOL_INIT_TIMEOUT
    mkdir -p "${HOME}/.config/ghostty"
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    enter_fake_install "${FAKE_BIN}"
    DISTROBOX="${FAKE_BIN}/distrobox"
    export FAKE_DOCKER_CALLS="${BATS_TEST_TMPDIR}/docker.calls"
    export FAKE_DISTROBOX_CALLS="${BATS_TEST_TMPDIR}/distrobox.calls"
    export FAKE_LOGS_PIDFILE="${BATS_TEST_TMPDIR}/logs.pid"
    export FAKE_LOGS_SCRIPT="${BATS_TEST_TMPDIR}/logs.script"
    export FAKE_STARTED_AT="${FAKE_ZERO_STARTED_AT}"
    export WORKTOOL_INIT_INTERVAL=1
    enter_fake_logs \
        '0|distrobox: Installing basic packages...' \
        '1|Unpacking pkg-1' \
        '1|Unpacking pkg-2' \
        '1|Unpacking pkg-3' \
        '1|container_setup_done'
}

teardown() {
    if enter_fake_logs_alive; then
        kill "$(cat "${FAKE_LOGS_PIDFILE}")" 2>/dev/null || true
    fi
}

@test "this spec is a required integration spec of test.sh" {
    run bash -c 'source "$1" && _required_specs integration' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "integration/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "just box enter on a never-started box: notice, progress, host log, then distrobox enter" {
    # The box namespace's own justfile (what `just box` loads): the root
    # justfile only `mod?`s it, and a checkout copy may not carry the root.
    PATH="${FAKE_BIN}:${PATH}" run just --justfile "${REPO_ROOT}/script/box/justfile.box" \
        enter --distrobox "${DISTROBOX}" -- fish
    assert_success
    assert_output --partial "first launch of box 'dev'"
    assert_output --partial "docker logs -f dev"
    assert_output --partial "${HOME}/.cache/worktool/dev-init.log"
    assert_line --regexp 'first launch: Installing basic packages\.\.\. - [0-9]+s elapsed - Unpacking pkg-[0-9]'
    assert_line --regexp 'initialisation complete after [0-9]+s'
    assert_line "FAKE-DISTROBOX enter dev -- fish"
    run cat "${HOME}/.cache/worktool/dev-init.log"
    assert_line "Unpacking pkg-3"
}

@test "the ghostty command just box setup writes enters the box directly without starting tmux" {
    run "${REPO_ROOT}/script/box/setup.sh" --terminal ghostty --distrobox "${DISTROBOX}"
    assert_success
    local _cmd
    _cmd="$(sed -n 's/^command = //p' "${HOME}/.config/ghostty/config")"
    [[ -n "${_cmd}" ]] || fail "setup wrote no ghostty command"
    # What ghostty runs, under a desktop session's reduced PATH (plus the
    # fake engine, which a real desktop session reaches at /usr/bin/docker).
    run env -i PATH="${FAKE_BIN}:/usr/bin:/bin" HOME="${HOME}" \
        WORKTOOL_INIT_INTERVAL=1 FAKE_STARTED_AT="${FAKE_STARTED_AT}" \
        FAKE_LOGS_SCRIPT="${FAKE_LOGS_SCRIPT}" FAKE_LOGS_PIDFILE="${FAKE_LOGS_PIDFILE}" \
        FAKE_DOCKER_CALLS="${FAKE_DOCKER_CALLS}" FAKE_DISTROBOX_CALLS="${FAKE_DISTROBOX_CALLS}" \
        /bin/sh -c "${_cmd}"
    assert_success
    assert_output "FAKE-DISTROBOX enter dev"
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
    run enter_fake_logs_alive
    assert_failure
}
