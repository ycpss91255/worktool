#!/usr/bin/env bats
# Representative fast coverage for the TDD commit hook. The complete
# scenario x launch-form product lives in test/matrix.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    MATRIX_SPEC="${REPO_ROOT}/test/matrix/enforce_tdd_commit_spec.bats"
}

@test "this representative spec is required by the unit tier" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/hook/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "unit representative: every commit-state scenario crosses the direct hook interface" {
    TDD_MATRIX_FORM="git commit -m x" run bats \
        --filter '^the acceptance matrix holds for a direct launch, bash -c and eval$' \
        "${MATRIX_SPEC}"
    assert_success
}

@test "unit representative: every launch form crosses the blocked commit-state interface" {
    TDD_MATRIX_CASE=product-after-green run bats \
        --filter '^the acceptance matrix holds for a direct launch, bash -c and eval$' \
        "${MATRIX_SPEC}"
    assert_success
}

@test "the moved full-product case exists in the matrix tier" {
    run grep -Fqx -- \
        '@test "the acceptance matrix holds for a direct launch, bash -c and eval" {' \
        "${MATRIX_SPEC}"
    assert_success
}
