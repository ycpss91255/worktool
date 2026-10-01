#!/usr/bin/env bats
# ADR 0010 invariant-specific wording guards.

load "${BATS_TEST_DIRNAME}/../../helper/common"

_adr_0010() {
    printf '%s\n' "${REPO_ROOT}/doc/adr/0010-invariant-black-box-verifiable.md"
}

_adr_0010_section() {
    awk -v h="## $1" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$(_adr_0010)"
}

_adr_0010_check_guard() {
    local _bt=$'\x60' _file _case
    _file="$(sed -n "s/^[^${_bt}]*${_bt}\\(test\/[^${_bt}]*\\.bats\\)${_bt}.*/\\1/p" <<<"$1")"
    [[ "$1" == *「*」* ]] || return 1
    _case="${1#*「}"
    _case="${_case%%」*}"
    [[ -n "${_file}" && -n "${_case}" ]] || return 1
    if ! grep -qxF "@test \"${_case}\" {" "${REPO_ROOT}/${_file}" 2>/dev/null; then
        printf '%s: %s\n' "${_file}" "${_case}"
        return 1
    fi
}

_adr_0010_check_guards() {
    local _adr="$1" _minimum="$2" _bt=$'\x60' _line _count=0 _failed=0
    while IFS= read -r _line; do
        _count=$((_count + 1))
        if ! _adr_0010_check_guard "${_line}"; then
            _failed=1
        fi
    done < <(awk '/^## 目前由哪些機制或測試守住$/ { on = 1; next }
        /^## / { on = 0 } on' "${_adr}" |
        grep -E "${_bt}test/[^${_bt}]*\\.bats${_bt}")
    [[ "${_count}" -ge "${_minimum}" ]] || return 1
    return "${_failed}"
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

@test "every spec case ADR 0010 cites as a guard exists under that exact name" {
    run _adr_0010_check_guards \
        "${BATS_TEST_DIRNAME}/../fixture/adr/9999-invariant-missing-guard.md" 1
    assert_failure
    assert_output --partial \
        "test/unit/justfile_spec.bats: fixture guard case that does not exist"

    run _adr_0010_check_guards "$(_adr_0010)" 3
    assert_success
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
