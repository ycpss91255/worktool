#!/usr/bin/env bats
# ADR 0004 invariant-specific wording guards.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    ADR_0004="${REPO_ROOT}/doc/adr/0004-invariant-user-content.md"
}

_adr4_guard_section() {
    sed -n '/^## 目前由哪些機制或測試守住/,/^## /p' "${ADR_0004}" | sed '1d;/^## /d'
}

_adr4_citations() {
    local _q='`'
    _adr4_guard_section \
        | grep -oE "${_q}test/[^${_q}]+\\.bats${_q}:「[^」]+」" \
        | sed -E "s/^${_q}([^${_q}]+)${_q}:「(.*)」\$/\\1\\t\\2/"
}

_adr4_definition() {
    sed -n '/^## 性質/,/^## /p' "${ADR_0004}" | grep -E '^「使用者寫的內容」'
}

_contract_invariant_1() {
    sed -n '/^## 6\./,$p' "${REPO_ROOT}/doc/contract.md" | grep -E '^1\. '
}

_contract_promise_1() {
    sed -n '/^## 4\./,/^## 5\./p' "${REPO_ROOT}/doc/contract.md" \
        | grep -A1 -E '^- \*\*使用者寫的內容歸使用者'
}

@test "ADR 0004 names its issue and its parent" {
    run grep -E '^- 討論：' "${ADR_0004}"
    assert_success
    assert_output --partial "#200"
    assert_output --partial "#202"
}

@test "every spec case ADR 0004 cites exists under that name in that file" {
    local _citations _file _case _n=0
    _citations="$(_adr4_citations)"
    [[ -n "${_citations}" ]] || fail "ADR 0004 cites no spec case"
    while IFS=$'\t' read -r _file _case; do
        _n=$((_n + 1))
        [[ -f "${REPO_ROOT}/${_file}" ]] || fail "cited spec missing: ${_file}"
        grep -qxF "@test \"${_case}\" {" "${REPO_ROOT}/${_file}" \
            || fail "no case '${_case}' in ${_file}"
    done <<<"${_citations}"
    assert [ "${_n}" -ge 5 ]
}

@test "ADR 0004 marks 'ask before changing' as not yet guarded (待補)" {
    run bash -c 'sed -n "/^## 目前由哪些機制或測試守住/,\$p" "$1" | grep -E "要改先問"' _ "${ADR_0004}"
    assert_success
    assert_output --partial "待補"
}

@test "ADR 0004 defines user content as what worktool did NOT write (a closed statement, not a question)" {
    run _adr4_definition
    assert_success
    refute_output --partial "是不是"
    assert_output --partial "不是由 worktool 寫出來的"
}

@test "ADR 0004 names every script that writes a user file: setup.sh and assemble.sh (home_record)" {
    run _adr4_guard_section
    assert_success
    refute_output --partial "只有 \`just box setup\`"
    assert_output --partial "script/box/setup.sh"
    assert_output --partial "script/box/assemble.sh"
    assert_output --partial "home_record"
    run _adr4_citations
    assert_success
    assert_output --regexp "test/[a-z]+/assemble_spec\.bats"
}

@test "doc/contract.md invariant index entry 1 links this ADR (issue #202 backfill)" {
    assert [ -f "${REPO_ROOT}/doc/adr/0004-invariant-user-content.md" ]
    assert [ -f "${REPO_ROOT}/doc/contract.md" ]
    run _contract_invariant_1
    assert_success
    assert_output --partial "](adr/0004-invariant-user-content.md)"
    assert_output --partial "#202"
    refute_output --partial "待寫"
}

@test "ADR 0004 states the state-file key ownership exception and lists the dropped user lines as 待補" {
    run sed -n '/^## 性質/,/^## /p' "${ADR_0004}"
    assert_success
    assert_output --partial "狀態鍵"
    assert_output --partial "\`~/.config/worktool/config\`"
    assert_output --partial "\`home.source\`"
    run _adr4_guard_section
    assert_success
    refute_output --partial "沒有刻意改動受管區塊以外既有內容的路徑"
    refute_output --partial "保留它不管的行"
    assert_output --regexp "狀態檔裡使用者自己加的行.*待補"
}

@test "doc/contract.md invariant-1 promise carries the state-key exception and the known state-file gap" {
    run _contract_promise_1
    assert_success
    [ "${#lines[@]}" -eq 2 ]
    assert_line --index 0 --partial "\`~/.config/worktool/config\`"
    assert_line --index 0 --partial "狀態鍵"
    assert_line --index 0 --partial "](adr/0004-invariant-user-content.md)"
    assert_line --index 1 --regexp "^  - 驗證：.*狀態檔裡使用者自己加的行.*待驗"
}
