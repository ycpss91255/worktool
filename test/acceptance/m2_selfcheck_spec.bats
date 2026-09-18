#!/usr/bin/env bats
# test/acceptance/m2_selfcheck_spec.bats - M2 acceptance: the delivered
# self-check passes against the delivered repo, and fails when it should.
#
# The acceptance tier verifies the DELIVERABLE the way a user receives it:
# it invokes the real public entry point `script/selfcheck.sh` (the one
# doc/manifest.md tells users to run) and asserts on its verdict. It does
# NOT re-implement the checks in bats - the script under test is the
# original file at its original path.
#
# What this proves: after a clean clone, `./script/selfcheck.sh` exits 0
# and prints ALL PASS (M2 acceptance criterion: dry-run assemble contract +
# every documented invalid-manifest rejection), from inside or outside the
# repo; and its verdict is not vacuous - a broken manifest and a wrapper
# that skips validation are both reported as SOME FAILED with exit 1.
#
# What this does not prove: a usable box. That is the system tier's job -
# test/system/real_engine_spec.bats (M2, docker-in-docker) proves it in CI;
# real hardware (performance, non-root user, GPU) stays on the human
# checklist (doc/manifest.md 驗收紀錄) and M3/M5.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    SELFCHECK="${REPO_ROOT}/script/selfcheck.sh"
    TMP="${BATS_TEST_TMPDIR}"
}

# Build a minimal, independent checkout copy (script/ lib/ box/) under $1 so
# a negative case can break ONE thing without touching the delivered repo.
_make_repo_copy() {
    local _dst="$1"
    mkdir -p "${_dst}"
    cp -R "${REPO_ROOT}/script" "${REPO_ROOT}/lib" "${REPO_ROOT}/box" "${_dst}/"
}

# --- positive: the delivered repo passes its own self-check ------------------

@test "selfcheck.sh is the delivered, executable public entry point" {
    assert [ -f "${SELFCHECK}" ]
    assert [ -x "${SELFCHECK}" ]
}

@test "selfcheck exits 0 and prints ALL PASS against the delivered repo" {
    cd "${REPO_ROOT}"
    run "${SELFCHECK}"
    assert_success
    assert_line "ALL PASS"
    refute_line --regexp '^FAIL'
    refute_line "SOME FAILED"
    # Every documented check reported PASS: the two dry-run contracts and the
    # seven invalid-manifest rejections (doc/manifest.md 3a-3e, including the
    # single-quoted blank image and the unbalanced-quote image).
    assert_line "PASS 3a"
    assert_line "PASS 3b"
    assert_line "PASS reject single-quoted-image.ini"
    assert_line "PASS reject unbalanced-quote-image.ini"
    assert_equal "$(printf '%s\n' "${lines[@]}" | grep -c '^PASS ')" "9"
}

@test "selfcheck works from outside the repo (defaults to its own checkout)" {
    cd "${TMP}"
    run "${SELFCHECK}"
    assert_success
    assert_line "ALL PASS"
}

# --- negative: the verdict is not vacuous ------------------------------------

@test "selfcheck exits non-zero and reports SOME FAILED on a broken manifest" {
    local _copy="${TMP}/broken-manifest"
    _make_repo_copy "${_copy}"
    # Break the delivered manifest: drop the required image.
    printf '[dev]\n' >"${_copy}/box/dev.ini"

    run "${SELFCHECK}" --root "${_copy}"
    assert_failure 1
    assert_line "SOME FAILED"
    refute_line "ALL PASS"
    # The dry-run contract checks are the ones that broke.
    assert_line --regexp '^FAIL 3a'
    assert_line --regexp '^FAIL 3b'
}

@test "selfcheck catches a wrapper that skips validation" {
    local _copy="${TMP}/no-validation"
    _make_repo_copy "${_copy}"
    # Shadow assemble.sh with one that accepts ANY manifest and always prints
    # the happy-path command: the positive dry-run check passes, but every
    # invalid-manifest rejection must now be reported as FAIL.
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "distrobox assemble create --file box/dev.ini\\n"\n'
    } >"${_copy}/script/assemble.sh"
    chmod +x "${_copy}/script/assemble.sh"

    run "${SELFCHECK}" --root "${_copy}"
    assert_failure 1
    assert_line "SOME FAILED"
    assert_line "PASS 3a"
    assert_line --regexp '^FAIL .*no-image\.ini'
    assert_line --regexp '^FAIL .*multi\.ini'
}

@test "selfcheck rejects an unusable --root with a clear error" {
    run "${SELFCHECK}" --root "${TMP}/does-not-exist"
    assert_failure
    assert_output --partial "does-not-exist"
    refute_line "ALL PASS"
}
