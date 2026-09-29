#!/usr/bin/env bats
# test/unit/config_owner_spec.bats - only lib/config.sh knows where the state
# file is, proven by BEHAVIOUR (issue #199 round 6).
#
# A text search cannot prove that a bash module never builds the path
# (`p=worktool; "$(config_xdg_dir)/$p/config"` passes any deny-list). So
# this spec moves the state file: lib/config.sh honours a test-only
# WORKTOOL_CONFIG_FILE, pointed at a random path, while the DEFAULT
# location ($XDG_CONFIG_HOME/worktool/config) holds a poisoned file:
#   - invalid decision values, a recorded home and a `link=` entry that
#     would each show up (or refuse the run) if anything read them;
#   - a snapshot of its bytes and of its directory, which must not change
#     (nothing may write there, not even a temp or lock file).
# Then every command that reads or writes the state file runs - setup,
# assemble, status (and through them lib/enter.sh, lib/home.sh and
# lib/link.sh, validators included) - and the spec requires every effect
# to come from the random path. A module that computes the path itself
# lands on the poison and fails a case here; test/unit/config_mutation_spec
# proves that with a rogue module.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CONFIG_HOME DBX_CONTAINER_CUSTOM_HOME
    mkdir -p "${HOME}"

    # The default location, poisoned.
    DEFAULT_DIR="${HOME}/.config/worktool"
    mkdir -p "${DEFAULT_DIR}"
    printf '%s\n' '# POISON: nothing may read or write this file' \
        'tmux=POISON' 'tmux.source=user' 'box=poison' 'box.source=user' \
        'home=/poison-home' 'home.source=user' 'link=.poison' >"${DEFAULT_DIR}/config"
    cp "${DEFAULT_DIR}/config" "${BATS_TEST_TMPDIR}/poison.orig"

    # The state file lib/config.sh is told to use: a random path.
    STATE="$(mktemp -d "${BATS_TEST_TMPDIR}/state.XXXXXX")/state"
    export WORKTOOL_CONFIG_FILE="${STATE}"
    printf '%s\n' '# mine' 'link=.aws' >"${STATE}"

    # distrobox and the container manager, faked: assemble runs for real.
    MOCKBIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${MOCKBIN}"
    printf '#!/bin/sh\nexit 0\n' >"${MOCKBIN}/distrobox"
    # `ps` lists no container (no box yet); anything else is an error.
    cat >"${MOCKBIN}/docker" <<'EOF'
#!/bin/sh
[ "$1" = ps ] && exit 0
exit 2
EOF
    chmod +x "${MOCKBIN}/distrobox" "${MOCKBIN}/docker"
    PATH="${MOCKBIN}:${PATH}"
    export PATH
    export DBX_CONTAINER_MANAGER=docker
    BOX_HOME="${BATS_TEST_TMPDIR}/box home"
}

# The default location is exactly as the case left it: same bytes, and
# nothing else (a temp file, a lock) was created next to it.
_assert_default_untouched() {
    run cmp -- "${BATS_TEST_TMPDIR}/poison.orig" "${DEFAULT_DIR}/config"
    assert_success
    run ls -A "${DEFAULT_DIR}"
    assert_output "config"
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "setup, assemble and status read and write only the state file lib/config.sh names" {
    run "${REPO_ROOT}/script/box/setup.sh" --tmux host
    assert_success
    assert_line "[INFO] wrote: ${STATE}"
    run "${REPO_ROOT}/script/box/assemble.sh" --home "${BOX_HOME}"
    assert_success
    assert_line "[INFO] recorded box home in ${STATE}"
    run "${REPO_ROOT}/script/box/status.sh"
    assert_success
    assert_line "config: ${STATE}"
    assert_line "tmux: host (user)"
    assert_line "box: dev (default)"
    assert_line "link: ${BOX_HOME}/.aws -> ${HOME}/.aws (missing source)"
    assert_line "home: ${BOX_HOME} (user)"
    refute_output --partial "poison"
    refute_output --partial "POISON"
    # Every writer's keys landed in the random file, the user's lines kept.
    run grep -cxE '# mine|link=\.aws|tmux=host|tmux\.source=user|home=.*/box home|home\.source=user' "${STATE}"
    assert_output "6"
    _assert_default_untouched
}

@test "the validators (lib/enter.sh, lib/home.sh) judge the state file lib/config.sh names" {
    printf '%s\n' 'tmux=sideways' >"${STATE}"
    run "${REPO_ROOT}/script/box/setup.sh"
    assert_failure 1
    assert_line "[ERROR] ${STATE}: invalid value 'sideways' for tmux (expected inside|host)"
    run "${REPO_ROOT}/script/box/status.sh"
    assert_failure 1
    printf '%s\n' 'home=relative' 'home.source=user' >"${STATE}"
    run "${REPO_ROOT}/script/box/assemble.sh"
    assert_failure 1
    assert_line "[ERROR] ${STATE}: invalid value 'relative' for home (expected an absolute path)"
    _assert_default_untouched
}

@test "a dry run and --help touch neither file" {
    cp "${STATE}" "${BATS_TEST_TMPDIR}/state.orig"
    run "${REPO_ROOT}/script/box/setup.sh" --dry-run
    assert_success
    run "${REPO_ROOT}/script/box/assemble.sh" --dry-run
    assert_success
    run "${REPO_ROOT}/script/box/setup.sh" --help
    assert_success
    run cmp -- "${BATS_TEST_TMPDIR}/state.orig" "${STATE}"
    assert_success
    _assert_default_untouched
}
