#!/usr/bin/env bats
# test/unit/selfcheck_spec.bats - script/test/selfcheck.sh CLI and path
# resolution after the move to script/test/ (M2)
#
# WHAT THIS PROVES
#   selfcheck.sh, now two levels below the repo root, still resolves the
#   root and the wrapper it checks (script/box/assemble.sh) - both for its
#   own checkout and for a `--root <copy>`; it owns `--help` (exit 0) and
#   refuses an unknown option with `selfcheck.sh: unknown option '<x>'
#   (see --help)` (exit 2) without running a single check. The full
#   PASS/FAIL contract is the acceptance tier's job
#   (test/acceptance/m2_selfcheck_spec.bats); this spec only pins the CLI
#   and the layout-dependent wiring.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    SELFCHECK="${REPO_ROOT}/script/test/selfcheck.sh"
    COPY="${BATS_TEST_TMPDIR}/copy"
}

# An independent checkout copy (script/ lib/ box/) at $COPY.
_make_repo_copy() {
    mkdir -p "${COPY}"
    cp -R "${REPO_ROOT}/script" "${REPO_ROOT}/lib" "${REPO_ROOT}/box" "${COPY}/"
}

@test "selfcheck.sh --help exits 0 and names --root" {
    run "${SELFCHECK}" --help
    assert_success
    assert_output --partial "--root"
    assert_output --partial "--help"
    refute_output --partial "PASS"
}

@test "selfcheck.sh -h is the same as --help" {
    run "${SELFCHECK}" --help
    local _long="${output}"
    run "${SELFCHECK}" -h
    assert_success
    assert_output "${_long}"
}

@test "selfcheck.sh --bogus exits 2 with the documented message and runs no check" {
    run "${SELFCHECK}" --bogus
    assert_failure 2
    assert_output "selfcheck.sh: unknown option '--bogus' (see --help)"
    refute_output --partial "PASS"
    refute_output --partial "FAIL"
}

@test "selfcheck.sh finds script/box/assemble.sh in its own checkout from script/test/" {
    cd "${BATS_TEST_TMPDIR}"
    run "${SELFCHECK}"
    assert_success
    assert_line "ALL PASS"
    assert_line "PASS 3a"
    assert_line "PASS 3b"
}

@test "selfcheck.sh --root <copy> checks that copy's script/box/assemble.sh" {
    _make_repo_copy
    run "${SELFCHECK}" --root "${COPY}"
    assert_success
    assert_line "ALL PASS"
    # 3b's expected path is the copy's, so the copy's wrapper is what ran.
    refute_output --partial "${REPO_ROOT}/box/dev.ini"
}

@test "selfcheck.sh --root refuses a tree whose script/box/assemble.sh is missing" {
    _make_repo_copy
    rm "${COPY}/script/box/assemble.sh"
    run "${SELFCHECK}" --root "${COPY}"
    assert_failure 2
    assert_output --partial "script/box/assemble.sh"
    refute_line "ALL PASS"
}
