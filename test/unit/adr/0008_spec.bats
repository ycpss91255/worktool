#!/usr/bin/env bats
# ADR 0008 invariant-specific wording guards.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    ADR_0008="${REPO_ROOT}/doc/adr/0008-invariant-minimal-interface.md"
}

_adr8_guard_section() {
    awk '/^## /{on = ($0 == "## 目前由哪些機制或測試守住")} on' "${ADR_0008}"
}

_adr8_citations() {
    local _bt=$'\x60'
    _adr8_guard_section |
        grep -oE "${_bt}test/[^${_bt}]+\\.bats${_bt}「[^」]+」" |
        sed -E "s/^${_bt}([^${_bt}]+)${_bt}「(.+)」\$/\\1\\t\\2/"
}

@test "ADR 0008 exists with the ADR header (title, status, discussion)" {
    assert [ -f "${ADR_0008}" ]
    run head -n 1 "${ADR_0008}"
    assert_output --regexp '^# 0008 '
    run grep -c -E '^- 狀態：已採納' "${ADR_0008}"
    assert_output "1"
    run grep -E '^- 討論：' "${ADR_0008}"
    assert_output --partial "#200"
    assert_output --partial "#206"
}

@test "ADR 0008 links the just command model in doc/design.md instead of restating it" {
    run grep -F "](../design.md" "${ADR_0008}"
    assert_success
    assert_output --partial "2026-09-16"
    run grep -cE "[*][*](零特例|namespace 以動作命名|justfile 是薄轉發器)" "${ADR_0008}"
    assert_output "0"
}

@test "every spec case ADR 0008 cites exists under that exact name" {
    local _spec _case _n=0
    while IFS=$'\t' read -r _spec _case; do
        _n=$((_n + 1))
        run grep -cF -- "@test \"${_case}\" {" "${REPO_ROOT}/${_spec}"
        assert_success
        assert_output "1"
    done < <(_adr8_citations)
    assert [ "${_n}" -ge 5 ]
}

@test "ADR 0008 writes the interface with an optional recipe and names the default recipe" {
    local _bt=$'\x60'
    run grep -cF "${_bt}just <namespace> <recipe>${_bt}" "${ADR_0008}"
    assert_output "0"
    run grep -F "${_bt}just <namespace> [<recipe>]${_bt}" "${ADR_0008}"
    assert_success
    run sed -n '/^## 性質/,/^## /p' "${ADR_0008}"
    assert_output --regexp "default.*recipe"
}

@test "ADR 0008 does not claim just and the bare script behave the same" {
    run _adr8_guard_section
    assert_success
    refute_output --partial "不會分歧"
    refute_output --partial "同一個行為"
    run sed -n '/^### 待補/,$p' "${ADR_0008}"
    assert_output --partial "行為等價"
}

@test "ADR 0008 header says the doc/contract.md index link is backfilled by #201" {
    run grep -E '^- 索引：' "${ADR_0008}"
    assert_success
    assert_output --partial "doc/contract.md"
    assert_output --partial "#201"
}
