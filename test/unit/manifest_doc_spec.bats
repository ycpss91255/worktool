#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

@test "#725: manifest describes the matrix tier as Cartesian-product coverage" {
    run grep -F 'just test matrix' "${REPO_ROOT}/doc/manifest.md"
    assert_success
    assert_output --partial '# 完整乘積矩陣 bats(test/matrix/)'
    assert_output --partial "所有測項 \`ok\`(完整乘積矩陣)"
    refute_output --partial '全產品矩陣'
}
