#!/usr/bin/env bats
# test/unit/adr_spec.bats - doc/adr wording guards
#
# WHAT THIS PROVES
#   ADR 0002 (the box owns its HOME, issue #197) records a decision whose
#   interfaces are NOT built yet: `just box assemble --home`, the refusal on
#   a HOME conflict, the user-config symlinks and TMUX_TMPDIR. Each of
#   decision items 2-4 must say so and name the issue that will build it
#   (#198 / #199 / #179), so nobody reads them as current behaviour
#   (codex round 1 on PR #222). The ADR must also not postpone the
#   architecture diagram: the repo rule is that a decision that changes a
#   diagram updates it in the same PR.
#
# Written test-first: RED against the round-0 ADR (present-tense items,
# diagram listed among the deferred rewrites), GREEN after the fix.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    ADR_0002="${REPO_ROOT}/doc/adr/0002-box-owns-its-home.md"
}

# Decision item $1 (the "N. ..." line under "## 決策") of ADR 0002.
_decision_item() {
    sed -n '/^## 決策/,/^## /p' "${ADR_0002}" | grep -E "^$1\. "
}

@test "ADR 0002 decision item 2 (--home path, conflict refusal) says #198 will implement it" {
    run _decision_item 2
    assert_success
    assert_output --partial "尚未實作"
    assert_output --partial "將由 #198 實作"
}

@test "ADR 0002 decision item 3 (user-config symlinks) says #199 will implement it" {
    run _decision_item 3
    assert_success
    assert_output --partial "尚未實作"
    assert_output --partial "將由 #199 實作"
}

@test "ADR 0002 decision item 4 (TMUX_TMPDIR) says #179 will implement it" {
    run _decision_item 4
    assert_success
    assert_output --partial "尚未實作"
    assert_output --partial "將由 #179 實作"
}

@test "ADR 0002 does not postpone the architecture diagram update" {
    # The deferral sentence (docs rewritten later by #198/#199/#179) must
    # not list the diagram ...
    run grep -E "各自改寫" "${ADR_0002}"
    assert_success
    refute_output --partial "架構圖"
    # ... and the ADR states the diagram is updated in this same change.
    run grep -c "架構圖.*同一個 PR" "${ADR_0002}"
    assert_success
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# --- ADR 0011: invariant 8 (minimal host dependencies), issue #209 ----------
#
# The ADR lists the specs that guard the invariant today. Each guard line
# names a spec file in backticks and one case in 「」; the file must exist and
# hold a @test with exactly that name, so the ADR cannot claim a guard that
# is not there (or survive a rename of it). Gaps are marked 待補.

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

@test "ADR 0011 exists with the invariant title and the four sections in order" {
    run head -n 1 "$(_adr_0011)"
    assert_success
    assert_output "# 0011 不變量 8：host 依賴最小，除驅動與 GUI app 外，只需 docker 與 just"
    run grep -E '^## ' "$(_adr_0011)"
    assert_success
    assert_line --index 0 "## 一句話"
    assert_line --index 1 "## 性質"
    assert_line --index 2 "## 為什麼固定"
    assert_line --index 3 "## 目前由哪些機制或測試守住"
    assert_equal "${#lines[@]}" 4
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

@test "ADR 0011 marks the unguarded parts as 待補 instead of claiming them" {
    run _adr_0011_section "目前由哪些機制或測試守住"
    assert_success
    assert_output --partial "待補"
}

@test "ADR 0011 does not hide that box actions still need distrobox on the host" {
    # assemble.sh / bench.sh exit 127 without distrobox on PATH today; the
    # guard section must say so rather than imply docker + just suffice.
    run _adr_0011_section "目前由哪些機制或測試守住"
    assert_success
    assert_output --partial "distrobox"
    assert_output --partial "127"
}

@test "ADR 0011 keeps #209 open until doc/contract.md backfills the invariant index" {
    # #209 also asks for the doc/contract.md index link; that file is not on
    # main yet (it lands with #201), so the ADR must record the backfill as
    # still owed and say #209 stays open (codex round 1 on PR #262).
    run _adr_0011_section "目前由哪些機制或測試守住"
    assert_success
    run grep -F "doc/contract.md" <<<"${output}"
    assert_success
    assert_output --partial "#209"
    assert_output --partial "#201"
    assert_output --partial "不關閉"
    assert_output --partial "待補"
}
