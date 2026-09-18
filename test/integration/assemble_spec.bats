#!/usr/bin/env bats
# test/integration/assemble_spec.bats - assemble -> distrobox wiring (M2)
#
# Proves the real (non-dry-run) path wires script/assemble.sh to the
# `distrobox assemble create --file box/dev.ini` invocation end-to-end,
# without needing real distrobox: a MOCK `distrobox` on PATH records the
# arguments it was called with, and the spec asserts on them.
#
# A real `distrobox assemble` (distrobox + docker/podman, docker-in-docker)
# is the system-level check deferred to M5 (see doc/design.md); this
# integration test verifies the wiring, not a real container build.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    ASSEMBLE="${REPO_ROOT}/script/assemble.sh"
    MOCKBIN="${BATS_TEST_TMPDIR}/bin"
    RECORD="${BATS_TEST_TMPDIR}/distrobox.args"
    mkdir -p "${MOCKBIN}"
    # Record-only stub: write the args it was invoked with, then succeed.
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$*" >"%s"\n' "${RECORD}"
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
    run cat "${RECORD}"
    assert_output "assemble create --file box/dev.ini"
}

@test "assemble validates box/dev.ini before invoking distrobox" {
    assert [ -f "${REPO_ROOT}/box/dev.ini" ]
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_success
    # The stub only runs after validation passes; its record must exist.
    assert [ -f "${RECORD}" ]
}
