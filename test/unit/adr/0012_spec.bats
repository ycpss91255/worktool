#!/usr/bin/env bats
# ADR 0012 invariant-specific wording guards.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    ADR_0012="${REPO_ROOT}/doc/adr/0012-invariant-platform-neutral.md"
}

_adr12_guard_section() {
    awk '/^## /{on = ($0 == "## 目前由哪些機制或測試守住")} on' "${ADR_0012}"
}

_adr12_citations() {
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
    done < <(_adr12_guard_section)
}

@test "ADR 0012 names its decision and follow-up issues" {
    run grep -E '^- 討論：' "${ADR_0012}"
    assert_success
    assert_output --partial "#200"
    assert_output --partial "#210"
    assert_output --partial "#148"
    assert_output --partial "#149"

    run grep -E '^- 索引：' "${ADR_0012}"
    assert_success
    assert_output --partial "doc/contract.md"
    assert_output --partial "由 #201 回填"
}

@test "ADR 0012 cites the CI matrix and real-engine specs as guards" {
    run _adr12_guard_section
    assert_success
    assert_output --partial "test/unit/ci_yml_spec.bats"
    assert_output --partial "test/system/real_engine_spec.bats"
}

@test "every named guard case ADR 0012 cites exists verbatim in its spec" {
    local _path _name _count=0 _missing=""
    while IFS=$'\t' read -r _path _name; do
        _count=$((_count + 1))
        grep -qF "@test \"${_name}\" {" "${REPO_ROOT}/${_path}" ||
            _missing+="${_path}: ${_name}"$'\n'
    done < <(_adr12_citations)
    assert [ "${_count}" -gt 0 ]
    assert_equal "${_missing}" ""
}

@test "ADR 0012 marks the Ubuntu 24.04 leg as pending under #148" {
    run _adr12_guard_section
    assert_success
    assert_line --regexp '24\.04.*待補.*#148|24\.04.*#148.*待補'
}

@test "ADR 0012 separates build-image from jobs that run tests" {
    run _adr12_guard_section
    assert_success
    refute_line --regexp 'build-image.*just test|just test.*build-image'
    assert_line --regexp 'build-image.*docker build'
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/adr/$(basename -- "${BATS_TEST_FILENAME}")"
}
