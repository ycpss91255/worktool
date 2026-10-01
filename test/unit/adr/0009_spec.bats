#!/usr/bin/env bats
# ADR 0009 invariant-specific wording guards.

load "${BATS_TEST_DIRNAME}/../../helper/common"

_adr_0009() {
    printf '%s\n' "${REPO_ROOT}/doc/adr/0009-invariant-idempotent.md"
}

_adr_0009_section() {
    awk -v h="## $1" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$(_adr_0009)"
}

_adr_0009_check_guard() {
    local _bt=$'\x60' _file _case
    _file="$(sed -n "s/^[^${_bt}]*${_bt}\(test\/[^${_bt}]*\.bats\)${_bt}.*/\1/p" <<<"$1")"
    [[ "$1" == *「*」* ]] || return 1
    _case="${1#*「}"
    _case="${_case%%」*}"
    [[ -n "${_file}" && -n "${_case}" ]] || return 1
    if ! grep -qxF "@test \"${_case}\" {" "${REPO_ROOT}/${_file}" 2>/dev/null; then
        printf '%s: %s\n' "${_file}" "${_case}"
        return 1
    fi
}

@test "ADR 0009 exists with the invariant title" {
    run head -n 1 "$(_adr_0009)"
    assert_success
    assert_output "# 0009 不變量 6：冪等，同一個指令重跑，結果相同"
}

@test "ADR 0009 names its discussion issues (#207, parent #200)" {
    run grep -E '^- 討論：' "$(_adr_0009)"
    assert_success
    assert_output --partial "#200"
    assert_output --partial "#207"
}

@test "every spec case ADR 0009 cites as a guard exists under that exact name" {
    local _bt=$'\x60' _line _count=0 _failed=0
    while IFS= read -r _line; do
        _count=$((_count + 1))
        if ! _adr_0009_check_guard "${_line}"; then
            _failed=1
        fi
    done < <(_adr_0009_section "目前由哪些機制或測試守住" |
        grep -E "${_bt}test/[^${_bt}]*\.bats${_bt}")
    assert [ "${_count}" -ge 3 ]
    assert_equal "${_failed}" 0
}

@test "ADR 0009 states only the same-input re-run rule of #200, no rule for changed inputs" {
    run _adr_0009_section "性質"
    assert_success
    refute_output --partial "不同的輸入"
    refute_output --partial "改了選擇"
    run _adr_0009_section "目前由哪些機制或測試守住"
    assert_success
    refute_output --partial "a changed decision replaces the block in place"
}

@test "ADR 0009 scopes the nothing-to-remove report to --auto-enter no" {
    run grep -F 'nothing to remove' "$(_adr_0009)"
    assert_success
    local _line
    for _line in "${lines[@]}"; do
        [[ "${_line}" == *"--auto-enter no"* ]] || fail "unscoped: ${_line}"
    done
}

@test "the doc/contract.md invariant index links invariant 6 to ADR 0009" {
    run grep -E '^6\. ' "${REPO_ROOT}/doc/contract.md"
    assert_success
    assert_output --partial "](adr/0009-invariant-idempotent.md)"
    assert_output --partial "#207"
    refute_output --partial "ADR 待寫"
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/adr/$(basename -- "${BATS_TEST_FILENAME}")"
}
