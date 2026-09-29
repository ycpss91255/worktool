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

# --- ADR 0009: invariant 6 (idempotent), issue #207 -------------------------
#
# The ADR lists the specs that guard the invariant today. Each guard line
# names a spec file in backticks and one case in 「」; the file must exist and
# hold a @test with exactly that name, so the ADR cannot claim a guard that
# is not there (or survive a rename of it). Gaps are marked 待補.

_adr_0009() {
    printf '%s\n' "${REPO_ROOT}/doc/adr/0009-invariant-idempotent.md"
}

# The body of section "## $1" of ADR 0009 (up to the next "## ").
_adr_0009_section() {
    awk -v h="## $1" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$(_adr_0009)"
}

# Check one guard line ($1): print "<file>: <case>" for a case that is
# missing, return 1 on a malformed line.
_adr_0009_check_guard() {
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

@test "ADR 0009 exists with the invariant title and the four sections in order" {
    run head -n 1 "$(_adr_0009)"
    assert_success
    assert_output "# 0009 不變量 6：冪等，同一個指令重跑，結果相同"
    run grep -E '^## ' "$(_adr_0009)"
    assert_success
    assert_line --index 0 "## 一句話"
    assert_line --index 1 "## 性質"
    assert_line --index 2 "## 為什麼固定"
    assert_line --index 3 "## 目前由哪些機制或測試守住"
    assert_equal "${#lines[@]}" 4
}

@test "ADR 0009 names its discussion issues (#207, parent #200)" {
    run grep -E '^- 討論：' "$(_adr_0009)"
    assert_success
    assert_output --partial "#200"
    assert_output --partial "#207"
}

@test "every spec case ADR 0009 cites as a guard exists under that exact name" {
    local _bt=$'\x60' _line _missing="" _n=0
    while IFS= read -r _line; do
        _n=$((_n + 1))
        run _adr_0009_check_guard "${_line}"
        assert_success
        _missing+="${output}"
    done < <(_adr_0009_section "目前由哪些機制或測試守住" | grep -E "${_bt}test/[^${_bt}]*\.bats${_bt}")
    assert [ "${_n}" -ge 3 ]
    assert_equal "${_missing}" ""
}

@test "ADR 0009 marks the unguarded parts as 待補 instead of claiming them" {
    run _adr_0009_section "目前由哪些機制或測試守住"
    assert_success
    assert_output --partial "待補"
}

# Codex round 1 on PR #250: #200 fixed invariant 6 as "the same command
# re-run gives the same result". The ADR must not add a rule for DIFFERENT
# inputs (converge, remove the old result), and must not cite a guard for
# that extra rule.
@test "ADR 0009 states only the same-input re-run rule of #200, no rule for changed inputs" {
    run _adr_0009_section "性質"
    assert_success
    refute_output --partial "不同的輸入"
    refute_output --partial "改了選擇"
    run _adr_0009_section "目前由哪些機制或測試守住"
    assert_success
    refute_output --partial "a changed decision replaces the block in place"
}

# Codex round 1 (non-blocking): only the --auto-enter no restore path
# reports "nothing to remove"; the ADR must not claim it for every removal.
@test "ADR 0009 scopes the nothing-to-remove report to --auto-enter no" {
    run grep -F 'nothing to remove' "$(_adr_0009)"
    assert_success
    local _line
    for _line in "${lines[@]}"; do
        [[ "${_line}" == *"--auto-enter no"* ]] || fail "unscoped: ${_line}"
    done
}

# Codex rounds 2-3 on PR #250: #207 also asks to backfill the invariant
# index of doc/contract.md. Item 6 must link ADR 0009 (and keep naming
# #207); it must no longer say the ADR is still to be written.
@test "the doc/contract.md invariant index links invariant 6 to ADR 0009" {
    run grep -E '^6\. ' "${REPO_ROOT}/doc/contract.md"
    assert_success
    assert_output --partial "](adr/0009-invariant-idempotent.md)"
    assert_output --partial "#207"
    refute_output --partial "ADR 待寫"
}
