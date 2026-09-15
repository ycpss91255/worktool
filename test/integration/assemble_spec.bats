#!/usr/bin/env bats
# test/integration/assemble_spec.bats - assemble -> distrobox wiring (M2)
#
# Proves the real (non-dry-run) path wires script/assemble.sh to the
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
    ASSEMBLE="${REPO_ROOT}/script/assemble.sh"
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
