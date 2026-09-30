#!/usr/bin/env bats
# ADR 0010 invariant-specific wording guards.

load "${BATS_TEST_DIRNAME}/../../helper/common"

_adr_0010() {
    printf '%s\n' "${REPO_ROOT}/doc/adr/0010-invariant-black-box-verifiable.md"
}

_adr_0010_section() {
    awk -v h="## $1" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$(_adr_0010)"
}

@test "ADR 0010 exists with the invariant title" {
    run head -n 1 "$(_adr_0010)"
    assert_success
    assert_output "# 0010 不變量 7：對外承諾必須黑箱可驗，開發與正式使用走同一個入口"
}

@test "ADR 0010 names its discussion issues (#208, parent #200)" {
    run grep -E '^- 討論：' "$(_adr_0010)"
    assert_success
    assert_output --partial "#200"
    assert_output --partial "#208"
}

@test "ADR 0010 cites at least three spec cases as guards" {
    local _count _bt=$'\x60'
    _count="$(_adr_0010_section 目前由哪些機制或測試守住 |
        grep -cE "${_bt}test/[^${_bt}]*\\.bats${_bt}")"
    assert [ "${_count}" -ge 3 ]
}

@test "ADR 0010 scopes the CI claim to the test gates and excludes build-image" {
    run bash -c 'grep -F ".github/workflows/ci.yml" | grep -E "^- CI "' \
        _ < <(_adr_0010_section 目前由哪些機制或測試守住)
    assert_success
    assert_equal "${#lines[@]}" 1
    refute_output --partial "每一個 gate"
    assert_output --partial "測試 gate"
    assert_output --partial "build-image"
    assert_output --partial "docker build"
}
