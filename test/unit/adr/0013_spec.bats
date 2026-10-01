#!/usr/bin/env bats
# ADR 0013 invariant-specific wording guards.

load "${BATS_TEST_DIRNAME}/../../helper/common"

_adr_0013() {
    printf '%s\n' "${REPO_ROOT}/doc/adr/0013-invariant-compatibility.md"
}

_adr_0013_section() {
    awk -v heading="## $1" '
        $0 == heading { found = 1; next }
        /^## / { if (found) exit }
        found { print }
    ' "$(_adr_0013)"
}

_adr_0013_citations() {
    local _line _path _rest _name _re="\`(test/[^\`]+\.bats)\`"
    while IFS= read -r _line; do
        [[ "${_line}" =~ ${_re} ]] || continue
        _path="${BASH_REMATCH[1]}" _rest="${_line}"
        while [[ "${_rest}" == *「*」* ]]; do
            _rest="${_rest#*「}"
            _name="${_rest%%」*}"
            _rest="${_rest#*」}"
            printf '%s\t%s\n' "${_path}" "${_name}"
        done
    done < <(_adr_0013_section 目前由哪些機制或測試守住)
}

@test "ADR 0013 states invariant 10 as decided in #200 and links #211" {
    run _adr_0013_section 一句話
    assert_success
    assert_output --partial "同一個大版號內不破壞原本的用法"

    run grep -E '^- 討論：.*#211.*#200' "$(_adr_0013)"
    assert_success
}

@test "every spec case ADR 0013 cites as a guard exists under that exact name" {
    local _path _name _count=0 _missing=""
    while IFS=$'\t' read -r _path _name; do
        _count=$((_count + 1))
        grep -qxF "@test \"${_name}\" {" "${REPO_ROOT}/${_path}" ||
            _missing+="${_path}: ${_name}"$'\n'
    done < <(_adr_0013_citations)
    assert [ "${_count}" -gt 0 ]
    assert_equal "${_missing}" ""
}

@test "ADR 0013 names all four pending compatibility guards" {
    local _guards
    _guards="$(_adr_0013_section 目前由哪些機制或測試守住)"
    assert_regex "${_guards}" '版本號本身：.*（待補）'
    assert_regex "${_guards}" '與上一個版本比對的相容性檢查：.*（待補）'
    assert_regex "${_guards}" '設定檔格式「只加不改」的檢查：.*（待補）'
    assert_regex "${_guards}" '大版號變動前公告升級步驟的機制（待補）'
}

@test "every repo path ADR 0013 names in backticks exists" {
    local _path _named=0 _bt=$'\x60'
    while IFS= read -r _path; do
        _named=$((_named + 1))
        assert [ -e "${REPO_ROOT}/${_path}" ]
    done < <(grep -oE "${_bt}(doc|test|script|lib)/[^${_bt} ]+${_bt}" \
        "$(_adr_0013)" | tr -d "${_bt}" | sort -u)
    assert [ "${_named}" -gt 0 ]
}

@test "ADR 0013 states its scope in place instead of deferring to doc/contract.md" {
    run _adr_0013_section 性質
    assert_success
    assert_output --partial "適用範圍"
    refute_output --partial "doc/contract.md"
}
