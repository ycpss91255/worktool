#!/usr/bin/env bats
# ADR 0006 invariant-specific wording guards.

load "${BATS_TEST_DIRNAME}/../../helper/common"

ADR_0006_NAME="0006-invariant-host-box-separation.md"

_adr_0006_section() {
    sed -n "/^## $1\$/,/^## /p" "${REPO_ROOT}/doc/adr/${ADR_0006_NAME}" |
        sed '1d;/^## /d'
}

@test "#204: ADR 0006 names ADR 0002 as the mechanism and #179 for tmux isolation" {
    run _adr_0006_section 目前由哪些機制或測試守住
    assert_success
    assert_output --partial "0002-box-owns-its-home.md"
    assert_output --partial "#179"
}

@test "#204: ADR 0006 status says property 3 is not yet in effect for --tmux host (#179)" {
    run grep -E '^- 狀態：' "${REPO_ROOT}/doc/adr/${ADR_0006_NAME}"
    assert_success
    assert_output --partial "尚未生效"
    assert_output --partial "--tmux host"
    assert_output --partial "#179"
}

@test "#204: ADR 0006 properties do not claim to hold unconditionally" {
    run _adr_0006_section 性質
    assert_success
    refute_line "以下三點必須永遠成立："
    assert_output --partial "尚未生效"
    assert_output --partial "--tmux host"
    assert_output --partial "#179"
}
