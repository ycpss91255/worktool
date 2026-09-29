#!/usr/bin/env bats
# test/integration/assemble_spec.bats - assemble -> distrobox wiring (M2)
#
# Proves the real (non-dry-run) path wires script/box/assemble.sh to the
# `distrobox assemble create --file box/dev.ini` invocation end-to-end,
# without needing real distrobox: a MOCK `distrobox` on PATH records the
# arguments it was called with, and the spec asserts on them.
#
# A real `distrobox assemble` against a real engine is the system tier's
# job and lives in M2: test/system/real_engine_spec.bats (docker-in-docker)
# proves the delivered manifest builds a usable box; M5 keeps only the
# broader environment matrix (real hardware, non-root user, other images).
# This integration test verifies the wiring, not a real container build.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    ASSEMBLE="${REPO_ROOT}/script/box/assemble.sh"
    MOCKBIN="${BATS_TEST_TMPDIR}/bin"
    RECORD="${BATS_TEST_TMPDIR}/distrobox.args"
    mkdir -p "${MOCKBIN}"
    # Record-only stub: write each arg on its OWN line (per-arg, not $*), so a
    # path containing spaces or shell metachars stays a single recorded token.
    # Then succeed.
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$@" >"%s"\n' "${RECORD}"
    } >"${MOCKBIN}/distrobox"
    chmod +x "${MOCKBIN}/distrobox"
    PATH="${MOCKBIN}:${PATH}"
    # Issue #199: a real assemble links user config into the box HOME, so
    # every case gets a throwaway HOME (the real home is never touched).
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CONFIG_HOME
    mkdir -p "${HOME}/.ssh"
    printf 'fake-private-key\n' >"${HOME}/.ssh/id_test"
}

@test "mock distrobox is the one that will be resolved on PATH" {
    run command -v distrobox
    assert_success
    assert_output "${MOCKBIN}/distrobox"
}

@test "assemble invokes distrobox assemble create with the dev manifest" {
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_success
    # Args are recorded one-per-line; assert each token independently.
    run cat "${RECORD}"
    assert_line --index 0 "assemble"
    assert_line --index 1 "create"
    assert_line --index 2 "--file"
    assert_line --index 3 "box/dev.ini"
}

@test "assemble validates box/dev.ini before invoking distrobox" {
    assert [ -f "${REPO_ROOT}/box/dev.ini" ]
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_success
    # The stub only runs after validation passes; its record must exist.
    assert [ -f "${RECORD}" ]
}

@test "assemble from outside the repo passes the resolved absolute path" {
    # From outside the repo, the relative default only resolves against
    # REPO_ROOT; distrobox must receive that same resolved absolute path, not
    # a bare `box/dev.ini` that would not exist from here.
    cd "${BATS_TEST_TMPDIR}"
    run "${ASSEMBLE}"
    assert_success
    run cat "${RECORD}"
    assert_line --index 2 "--file"
    assert_line --index 3 "${REPO_ROOT}/box/dev.ini"
}

@test "an invalid manifest never invokes distrobox" {
    # Validation must fail-fast BEFORE any real distrobox call: the mock must
    # never run (no record file) and the wrapper must exit non-zero.
    local _bad="${BATS_TEST_TMPDIR}/bad.ini"
    printf '[dev]\n' >"${_bad}"
    run "${ASSEMBLE}" --file "${_bad}"
    assert_failure
    assert [ ! -f "${RECORD}" ]
}

@test "an image with an unbalanced quote never invokes distrobox" {
    # distrobox-assemble sources `image='ubuntu:26.04"` as a shell
    # assignment, where the unbalanced quote is a syntax error. worktool's
    # pre-flight must reject it (exit 1, its own clear message) so distrobox
    # is never called: the mock records zero calls.
    local _bad="${BATS_TEST_TMPDIR}/unbalanced.ini"
    printf "[dev]\nimage='ubuntu:26.04\"\n" >"${_bad}"
    run "${ASSEMBLE}" --file "${_bad}"
    assert_failure 1
    assert_output --partial "unbalanced quote"
    assert [ ! -f "${RECORD}" ]
}

# --- issue #199: user config is linked into the box HOME after create -------

@test "#199: after a successful create the user config is linked into ~/<box>-box and logged" {
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_success
    assert_equal "$(readlink "${HOME}/dev-box/.ssh")" "${HOME}/.ssh"
    assert_equal "$(cat "${HOME}/dev-box/.ssh/id_test")" "fake-private-key"
    assert_line "[INFO] link: ${HOME}/dev-box/.ssh -> ${HOME}/.ssh"
    # The box name comes from the manifest section.
    local _other="${BATS_TEST_TMPDIR}/work.ini"
    printf '[work]\nimage=ubuntu:26.04\n' >"${_other}"
    run "${ASSEMBLE}" --file "${_other}"
    assert_success
    assert_equal "$(readlink "${HOME}/work-box/.ssh")" "${HOME}/.ssh"
}

@test "#199: an existing entry in the box HOME survives assemble with a warning" {
    mkdir -p "${HOME}/dev-box/.ssh"
    printf 'box-own\n' >"${HOME}/dev-box/.ssh/id_test"
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_success
    [[ ! -L "${HOME}/dev-box/.ssh" ]] || fail "the existing .ssh was replaced"
    assert_equal "$(cat "${HOME}/dev-box/.ssh/id_test")" "box-own"
    assert_equal "$(cat "${HOME}/.ssh/id_test")" "fake-private-key"
    assert_output --partial "[WARN]"
}

@test "#199: a failed create links nothing" {
    printf '#!/usr/bin/env bash\nexit 1\n' >"${MOCKBIN}/distrobox"
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_failure 1
    [[ ! -e "${HOME}/dev-box" ]] || fail "the box HOME was touched after a failed create"
}

@test "#199: dry-run links nothing" {
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}" --dry-run
    assert_success
    [[ ! -e "${HOME}/dev-box" ]] || fail "dry-run touched the box HOME"
}
