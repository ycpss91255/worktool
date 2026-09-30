#!/usr/bin/env bats
# Fast representative coverage; complete products live in test/matrix.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    MATRIX_SPEC="${REPO_ROOT}/test/matrix/enforce_main_checkout_readonly_spec.bats"
}

@test "unit representative: an Edit in the main checkout is blocked" {
    run bats --filter '^matrix: file location x Edit Write MultiEdit$' "${MATRIX_SPEC}"
    assert_success
}

@test "unit representative: mutating git covers operation location and wrapper dimensions" {
    run bats --filter '^matrix: mutating git command x main worktree git-C x direct bash-c eval$' "${MATRIX_SPEC}"
    assert_success
}

@test "unit representative: allowed git and gh pass" {
    run bats --filter '^(matrix: allowed git command x main worktree git-C x direct bash-c eval|gh is allowed from the main checkout)$' "${MATRIX_SPEC}"
    assert_success
}
