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
#
#   ADR 0007 (invariant 4, never fail silently, issue #205) lists the specs
#   and cases that guard the invariant. Every cited `<spec>`「<case>」 must
#   name a spec that exists and a case that spec defines, so the list cannot
#   claim a guard that is not there (or drift when a case is renamed). The
#   ADR also links the mechanism ADRs 0001 (errexit) and 0003 (exit 3).
#   It must not over-claim where exit codes are documented (they are split
#   over doc/structure.md, doc/manifest.md and doc/enter.md and cover only
#   some commands), and since the doc/contract.md index backfill #205 asks
#   for is not in this change, it must say #205 stays open (codex round 1
#   on PR #254).

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    ADR_0002="${REPO_ROOT}/doc/adr/0002-box-owns-its-home.md"
    ADR_0007="${REPO_ROOT}/doc/adr/0007-invariant-no-silent-failure.md"
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

# Every `<spec>`「<case>」 citation of ADR 0007, one per line as
# "<spec>\t<case>".
_adr_0007_citations() {
    # The backtick is held in a variable so the patterns can be
    # double-quoted without a command substitution.
    local _bt=$'\x60'
    grep -oE "${_bt}test/[^${_bt}]+\\.bats${_bt}「[^」]+」" "${ADR_0007}" \
        | sed -E "s/^${_bt}([^${_bt}]+)${_bt}「(.+)」\$/\\1\\t\\2/"
}

@test "ADR 0007 has the four invariant sections" {
    local _h
    for _h in "## 一句話" "## 性質" "## 為什麼固定" "## 目前由哪些機制或測試守住"; do
        run grep -cx -- "${_h}" "${ADR_0007}"
        assert_success
        assert_output "1"
    done
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
    # The list is not empty: a format change that hides every citation from
    # this check must fail, not pass vacuously.
    assert [ "${_n}" -ge 10 ]
}

@test "ADR 0007 marks the parts nothing checks yet as 待補" {
    run grep -c "待補" "${ADR_0007}"
    assert_success
}

# Subsection "### $1" of ADR 0007, up to the next "### " heading.
_adr_0007_section() {
    sed -n "/^### $1\$/,/^### /p" "${ADR_0007}" | sed '1d;/^### /d'
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
    # Only some commands and exit paths are documented; the ADR must not
    # read as if every command's codes were.
    run _adr_0007_section "性質 3：退出碼是對外契約"
    refute_output --partial "各指令的退出碼寫在"
    assert_output --partial "只記載了部分"
}

@test "ADR 0007 keeps #205 open until doc/contract.md backfills the invariant index" {
    run _adr_0007_section "待補"
    assert_success
    run grep -F "doc/contract.md" <<<"${output}"
    assert_success
    assert_output --partial "#205"
    assert_output --partial "不關閉"
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}
