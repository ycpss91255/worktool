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
# The box HOME is the manifest's `home=` (ADR 0002 decision 1). The
# delivered box/dev.ini has none yet (#198 adds it), so the dev box shares
# the host HOME: nothing is linked and the log says why.

# A manifest for box `work` whose HOME is ~/work-home. Prints its path.
_home_manifest() {
    local _m="${BATS_TEST_TMPDIR}/work.ini"
    printf '[work]\nimage=ubuntu:26.04\nhome=~/work-home\n' >"${_m}"
    printf '%s\n' "${_m}"
}

@test "#199: a box that shares the host HOME gets no links, and the log says so" {
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_success
    [[ ! -e "${HOME}/dev-box" ]] || fail "a box HOME was created for a box that has none"
    assert_output --partial "[INFO] link: box dev shares the host HOME (no home= in box/dev.ini) - user config already in place"
}

@test "#199: after a successful create the user config is linked into the manifest's home= and logged" {
    local _m
    _m="$(_home_manifest)"
    run "${ASSEMBLE}" --file "${_m}"
    assert_success
    assert_equal "$(readlink "${HOME}/work-home/.ssh")" "${HOME}/.ssh"
    assert_equal "$(cat "${HOME}/work-home/.ssh/id_test")" "fake-private-key"
    assert_line "[INFO] link: ${HOME}/work-home/.ssh -> ${HOME}/.ssh"
}

@test "#199: an existing entry in the box HOME survives assemble with a warning" {
    local _m
    _m="$(_home_manifest)"
    mkdir -p "${HOME}/work-home/.ssh"
    printf 'box-own\n' >"${HOME}/work-home/.ssh/id_test"
    run "${ASSEMBLE}" --file "${_m}"
    assert_success
    [[ ! -L "${HOME}/work-home/.ssh" ]] || fail "the existing .ssh was replaced"
    assert_equal "$(cat "${HOME}/work-home/.ssh/id_test")" "box-own"
    assert_equal "$(cat "${HOME}/.ssh/id_test")" "fake-private-key"
    assert_output --partial "[WARN]"
}

@test "#199: a failed create links nothing" {
    local _m
    _m="$(_home_manifest)"
    printf '#!/usr/bin/env bash\nexit 1\n' >"${MOCKBIN}/distrobox"
    run "${ASSEMBLE}" --file "${_m}"
    assert_failure 1
    [[ ! -e "${HOME}/work-home" ]] || fail "the box HOME was touched after a failed create"
}

@test "#199: dry-run links nothing" {
    local _m
    _m="$(_home_manifest)"
    run "${ASSEMBLE}" --dry-run --file "${_m}"
    assert_success
    [[ ! -e "${HOME}/work-home" ]] || fail "dry-run touched the box HOME"
}

@test "#199: a home= that cannot be resolved is refused before distrobox runs" {
    local _m="${BATS_TEST_TMPDIR}/bad.ini"
    printf '[work]\nimage=ubuntu:26.04\nhome=relative/dir\n' >"${_m}"
    run "${ASSEMBLE}" --file "${_m}"
    assert_failure 1
    assert_output --partial "relative/dir"
    assert [ ! -f "${RECORD}" ]
}
