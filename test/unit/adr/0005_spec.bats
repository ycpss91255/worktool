#!/usr/bin/env bats
# ADR 0005 invariant-specific wording guards.

load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    ADR_0005="${REPO_ROOT}/doc/adr/0005-invariant-single-source.md"
}

_adr5_guard_section() {
    awk '/^## /{on = ($0 == "## 目前由哪些機制或測試守住")} on' "${ADR_0005}"
}

_adr5_citations() {
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
    done < <(_adr5_guard_section)
}

_hardcoded_box_name_files() {
    grep -rlE "^[^#]*(=[\"']dev[\"']|printf 'dev\\\\n')" \
        --include='*.sh' "${REPO_ROOT}/lib" "${REPO_ROOT}/script" |
        sed "s|^${REPO_ROOT}/||" | sort
}

@test "ADR 0005 exists with the ADR header (title, status, discussion)" {
    assert [ -f "${ADR_0005}" ]
    run head -n 1 "${ADR_0005}"
    assert_output --regexp '^# 0005 '
    run grep -c -E '^- 狀態：已採納' "${ADR_0005}"
    assert_output "1"
    run grep -E '^- 討論：' "${ADR_0005}"
    assert_output --partial "#200"
    assert_output --partial "#203"
}

@test "ADR 0005 cites at least one spec case" {
    run _adr5_citations
    assert_success
    assert_line --regexp $'^test/[^[:space:]]+\\.bats\t.+$'
}

@test "every spec case ADR 0005 cites exists verbatim as an @test in that spec" {
    local _path _name _missing=""
    while IFS=$'\t' read -r _path _name; do
        grep -qF "@test \"${_name}\" {" "${REPO_ROOT}/${_path}" ||
            _missing+="${_path}: ${_name}"$'\n'
    done < <(_adr5_citations)
    assert_equal "${_missing}" ""
}

@test "ADR 0005 lists every file that hardcodes a second copy of the box name dev (codex round 1)" {
    local _file _missing=""
    run _hardcoded_box_name_files
    assert_success
    assert_line "lib/enter.sh"
    assert_line "script/box/bench.sh"
    while IFS= read -r _file; do
        _adr5_guard_section | grep -qF "\`${_file}\`" || _missing+="${_file}"$'\n'
    done < <(_hardcoded_box_name_files)
    assert_equal "${_missing}" ""
}

@test "ADR 0005 says the doc/contract.md invariant index link is backfilled by #201 (codex round 1)" {
    run grep -E '^- 索引：' "${ADR_0005}"
    assert_success
    assert_output --partial "doc/contract.md"
    assert_output --partial "#201"
}
