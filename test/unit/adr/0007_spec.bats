#!/usr/bin/env bats
# ADR 0007 invariant-specific wording guards.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    ADR_0007="${REPO_ROOT}/doc/adr/0007-invariant-no-silent-failure.md"
}

_adr_0007_section() {
    sed -n "/^### $1\$/,/^### /p" "${ADR_0007}" | sed '1d;/^### /d'
}

_adr_0007_citations() {
    local _bt=$'\x60'
    grep -oE "${_bt}test/[^${_bt}]+\.bats${_bt}「[^」]+」" "${ADR_0007}" |
        sed -E "s/^${_bt}([^${_bt}]+)${_bt}「(.+)」\$/\1\t\2/"
}

_contract_index_item() {
    sed -n '/^## 6\. /,$p' "${REPO_ROOT}/doc/contract.md" | grep -E "^$1\. "
}

@test "ADR 0007 links the mechanism ADRs 0001 (errexit) and 0003 (inconclusive exit 3)" {
    local _adr
    for _adr in 0001-scripts-use-errexit.md 0003-latency-gate-inconclusive.md; do
        assert [ -f "${REPO_ROOT}/doc/adr/${_adr}" ]
        run grep -c "](${_adr})" "${ADR_0007}"
        assert_success
    done
}

@test "every spec case ADR 0007 cites exists under that exact name" {
    local _spec _case _n=0
    while IFS=$'\t' read -r _spec _case; do
        _n=$((_n + 1))
        assert [ -f "${REPO_ROOT}/${_spec}" ]
        run grep -cF -- "@test \"${_case}\" {" "${REPO_ROOT}/${_spec}"
        assert_success
        assert_output "1"
    done < <(_adr_0007_citations)
    assert [ "${_n}" -ge 10 ]
}

@test "ADR 0007 names every doc holding exit codes, in both 性質 3 and 待補, without claiming all are written down" {
    local _sec _doc
    for _sec in "性質 3：退出碼是對外契約" "待補"; do
        run _adr_0007_section "${_sec}"
        assert_success
        refute_output ""
        for _doc in doc/structure.md doc/manifest.md doc/enter.md; do
            assert_output --partial "${_doc}"
        done
    done
    run _adr_0007_section "性質 3：退出碼是對外契約"
    refute_output --partial "各指令的退出碼寫在"
    assert_output --partial "只記載了部分"
}

@test "doc/contract.md invariant index item 4 links ADR 0007 and still names #205" {
    run _contract_index_item 4
    assert_success
    assert_output --partial "永不靜默失敗"
    assert_output --partial "](adr/0007-invariant-no-silent-failure.md)"
    assert_output --partial "#205"
    refute_output --partial "ADR 待寫"
}

@test "ADR 0007 does not defer the contract index backfill or keep #205 open" {
    run _adr_0007_section "待補"
    assert_success
    refute_output --partial "不關閉"
    refute_output --partial "回填"
}
