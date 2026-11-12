#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

_matrix_result_section() {
    local section="${BATS_TEST_TMPDIR}/matrix-section"
    awk '/^- 預期輸出:/ { inside=1; found++ ; next } inside && /^- 任一 gate/ { closed++; exit } inside { print } END { if (found != 1 || closed != 1) exit 1 }' "$1" >"${section}" || return 1
    grep -Fx "  - \`just test matrix\`:所有測項 \`ok\`(完整乘積矩陣),結尾 \`[ci] matrix bats OK\`。" "${section}"
}

@test "manifest describes the matrix tier and its expected result" {
    run grep -F 'just test matrix        # 完整乘積矩陣 bats(test/matrix/)' "${REPO_ROOT}/doc/manifest.md"
    assert_success
    run _matrix_result_section "${REPO_ROOT}/doc/manifest.md"
    assert_success
    run grep -F '全產品矩陣' "${REPO_ROOT}/doc/manifest.md"
    assert_failure
}

@test "the public matrix recipe describes the full product and forwards to the matrix tier" {
    run grep -A 2 -F '# Full-product matrix bats (test/matrix/); slow and required by CI.' "${REPO_ROOT}/script/test/justfile.test"
    assert_success
    assert_line 'matrix *args:'
    assert_line '    ./script/test/test.sh --matrix "$@"'
}

@test "matrix result outside the expected output list is not accepted" {
    local doc="${BATS_TEST_TMPDIR}/manifest.md"
    awk '/^  - .*matrix bats OK/ { saved=$0; next } /^- 任一 gate/ { print; print saved; next } { print }' "${REPO_ROOT}/doc/manifest.md" >"${doc}"
    run _matrix_result_section "${doc}"
    assert_failure
}
