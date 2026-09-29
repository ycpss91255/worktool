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
#   ADR 0008 (invariant 5, minimal interface, issue #206) records an
#   invariant. It carries the four sections #200 fixed for every invariant
#   ADR, links the just command model in doc/design.md (decision
#   2026-09-16) instead of restating it, and its guard section does not
#   overclaim: every cited `<spec>`「<case>」 exists verbatim in that spec,
#   and what nothing checks yet is marked 待補. Written test-first: RED
#   while the ADR does not exist.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    ADR_0002="${REPO_ROOT}/doc/adr/0002-box-owns-its-home.md"
    ADR_0008="${REPO_ROOT}/doc/adr/0008-invariant-minimal-interface.md"
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

# The "## 目前由哪些機制或測試守住" section of ADR 0008, up to the next "## ".
_adr8_guard_section() {
    awk '/^## /{on = ($0 == "## 目前由哪些機制或測試守住")} on' "${ADR_0008}"
}

# Every `<spec>`「<case>」 citation of ADR 0008's guard section, one per
# line as "<spec>\t<case>".
_adr8_citations() {
    # The backtick is held in a variable so the patterns can be
    # double-quoted without a command substitution.
    local _bt=$'\x60'
    _adr8_guard_section \
        | grep -oE "${_bt}test/[^${_bt}]+\\.bats${_bt}「[^」]+」" \
        | sed -E "s/^${_bt}([^${_bt}]+)${_bt}「(.+)」\$/\\1\\t\\2/"
}

@test "ADR 0008 exists with the ADR header (title, status, discussion)" {
    assert [ -f "${ADR_0008}" ]
    run head -n 1 "${ADR_0008}"
    assert_output --regexp '^# 0008 '
    run grep -c -E '^- 狀態：已採納' "${ADR_0008}"
    assert_output "1"
    run grep -E '^- 討論：' "${ADR_0008}"
    assert_output --partial "#200"
    assert_output --partial "#206"
}

@test "ADR 0008 has the four invariant sections of #200, in order" {
    run grep -E '^## ' "${ADR_0008}"
    assert_success
    assert_equal "${#lines[@]}" 4
    assert_line --index 0 "## 一句話"
    assert_line --index 1 "## 性質"
    assert_line --index 2 "## 為什麼固定"
    assert_line --index 3 "## 目前由哪些機制或測試守住"
}

@test "ADR 0008 links the just command model in doc/design.md instead of restating it" {
    run grep -F "](../design.md" "${ADR_0008}"
    assert_success
    assert_output --partial "2026-09-16"
    # The five rules stay in design.md: none of their bold headings is copied.
    run grep -cE "[*][*](零特例|namespace 以動作命名|justfile 是薄轉發器)" "${ADR_0008}"
    assert_output "0"
}

@test "every spec case ADR 0008 cites exists under that exact name" {
    local _spec _case _n=0
    assert [ -f "${ADR_0008}" ]
    while IFS=$'\t' read -r _spec _case; do
        _n=$((_n + 1))
        assert [ -f "${REPO_ROOT}/${_spec}" ]
        run grep -cF -- "@test \"${_case}\" {" "${REPO_ROOT}/${_spec}"
        assert_success
        assert_output "1"
    done < <(_adr8_citations)
    # A format change that hides every citation must fail, not pass vacuously.
    assert [ "${_n}" -ge 5 ]
}

@test "ADR 0008 marks the parts nothing checks yet as 待補" {
    run _adr8_guard_section
    assert_success
    assert_output --partial "待補"
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}
