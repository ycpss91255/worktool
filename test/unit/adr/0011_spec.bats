#!/usr/bin/env bats
# ADR 0011 invariant-specific wording guards.

load "${BATS_TEST_DIRNAME}/../../helper/common"

_adr_0011() {
    printf '%s\n' "${REPO_ROOT}/doc/adr/0011-invariant-minimal-host-deps.md"
}

# The body of section "## $1" of ADR 0011 (up to the next "## ").
_adr_0011_section() {
    awk -v h="## $1" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$(_adr_0011)"
}

# Check one guard line ($1): print "<file>: <case>" for a case that is
# missing, return 1 on a malformed line.
_adr_0011_check_guard() {
    local _bt=$'\x60' _file _case
    _file="$(sed -n "s/^[^${_bt}]*${_bt}\(test\/[^${_bt}]*\.bats\)${_bt}.*/\1/p" <<<"$1")"
    # Plain substring cuts, not a bracket expression: under the C locale a
    # [^「] class would work on single bytes of the multibyte characters.
    [[ "$1" == *「*」* ]] || return 1
    _case="${1#*「}"
    _case="${_case%%」*}"
    [[ -n "${_file}" && -n "${_case}" ]] || return 1
    if ! grep -qxF "@test \"${_case}\" {" "${REPO_ROOT}/${_file}" 2>/dev/null; then
        printf '%s: %s\n' "${_file}" "${_case}"
    fi
}

@test "ADR 0011 exists with the invariant title" {
    run head -n 1 "$(_adr_0011)"
    assert_success
    assert_output "# 0011 不變量 8：host 依賴最小，除驅動與 GUI app 外，只需 docker 與 just"
}

@test "ADR 0011 names its discussion issues (#209, parent #200)" {
    run grep -E '^- 討論：' "$(_adr_0011)"
    assert_success
    assert_output --partial "#200"
    assert_output --partial "#209"
}

@test "every spec case ADR 0011 cites as a guard exists under that exact name" {
    local _bt=$'\x60' _line _missing="" _n=0
    while IFS= read -r _line; do
        _n=$((_n + 1))
        run _adr_0011_check_guard "${_line}"
        assert_success
        _missing+="${output}"
    done < <(_adr_0011_section "目前由哪些機制或測試守住" | grep -E "${_bt}test/[^${_bt}]*\.bats${_bt}")
    assert [ "${_n}" -ge 3 ]
    assert_equal "${_missing}" ""
}

@test "ADR 0011 does not hide that box actions still need distrobox on the host" {
    # assemble.sh / bench.sh exit 127 without distrobox on PATH today; the
    # guard section must say so rather than imply docker + just suffice.
    run _adr_0011_section "目前由哪些機制或測試守住"
    assert_success
    assert_output --partial "distrobox"
    assert_output --partial "127"
}

@test "ADR 0011 hands the doc/contract.md index backfill to #264, split out of #209" {
    # #209 asked for the doc/contract.md index link, but that file lands with
    # #201; the backfill was split into its own issue #264 so #209 is one PR
    # (codex round 2 on PR #262). The ADR must name #264 and #201, and must
    # no longer claim #209 stays open for it.
    run _adr_0011_section "目前由哪些機制或測試守住"
    assert_success
    local _section="${output}"
    run grep -F "doc/contract.md" <<<"${_section}"
    assert_success
    assert_output --partial "#264"
    assert_output --partial "#201"
    assert_output --partial "#209"
    assert_output --partial "拆出"
    run grep -F "不關閉" <<<"${_section}"
    assert_failure
}

@test "ADR 0011 spec is required by the unit gate" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/adr/0011_spec.bats"
}
