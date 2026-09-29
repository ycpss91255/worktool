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
#   ADR 0004 (invariant 1, user content belongs to the user, issue #202)
#   lists the specs that guard the invariant. Every cited case must exist
#   under that exact name in that exact spec file, so the ADR cannot claim
#   a guard nobody runs; and "ask before changing", which nothing enforces
#   yet, must stay marked as a gap (待補).
#   Codex round 1 on PR #253: the definition must be a closed statement
#   (user content is what worktool did NOT write), the guard section must
#   name every writer of a user file (setup.sh AND assemble.sh through
#   home_record), and doc/contract.md, once #201 creates it, must link
#   invariant 1 to this ADR. RED against the round-0 ADR, GREEN after.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    ADR_0002="${REPO_ROOT}/doc/adr/0002-box-owns-its-home.md"
    ADR_0004="${REPO_ROOT}/doc/adr/0004-invariant-user-content.md"
}

# The "## 目前由哪些機制或測試守住" section of ADR 0004, heading excluded.
_adr4_guard_section() {
    sed -n '/^## 目前由哪些機制或測試守住/,/^## /p' "${ADR_0004}" | sed '1d;/^## /d'
}

# Every spec citation in the guard section, one `<file>\t<case>` per line.
# A citation is written `test/<...>.bats`:「<case name>」.
_adr4_citations() {
    local _q='`'
    _adr4_guard_section \
        | grep -oE "${_q}test/[^${_q}]+\\.bats${_q}:「[^」]+」" \
        | sed -E "s/^${_q}([^${_q}]+)${_q}:「(.*)」\$/\\1\\t\\2/"
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

@test "ADR 0004 has the four invariant sections, in order" {
    run grep -E '^## ' "${ADR_0004}"
    assert_success
    assert_line --index 0 "## 一句話"
    assert_line --index 1 "## 性質"
    assert_line --index 2 "## 為什麼固定"
    assert_line --index 3 "## 目前由哪些機制或測試守住"
}

@test "ADR 0004 names its issue and its parent" {
    run grep -E '^- 討論：' "${ADR_0004}"
    assert_success
    assert_output --partial "#200"
    assert_output --partial "#202"
}

@test "every spec case ADR 0004 cites exists under that name in that file" {
    local _citations _file _case _n=0
    _citations="$(_adr4_citations)"
    [[ -n "${_citations}" ]] || fail "ADR 0004 cites no spec case"
    while IFS=$'\t' read -r _file _case; do
        _n=$((_n + 1))
        [[ -f "${REPO_ROOT}/${_file}" ]] || fail "cited spec missing: ${_file}"
        grep -qxF "@test \"${_case}\" {" "${REPO_ROOT}/${_file}" \
            || fail "no case '${_case}' in ${_file}"
    done <<<"${_citations}"
    assert [ "${_n}" -ge 5 ]
}

@test "ADR 0004 marks 'ask before changing' as not yet guarded (待補)" {
    run bash -c 'sed -n "/^## 目前由哪些機制或測試守住/,\$p" "$1" | grep -E "要改先問"' _ "${ADR_0004}"
    assert_success
    assert_output --partial "待補"
}

# The definition paragraph (the first line of "## 性質" that defines the term).
_adr4_definition() {
    sed -n '/^## 性質/,/^## /p' "${ADR_0004}" | grep -E '^「使用者寫的內容」'
}

@test "ADR 0004 defines user content as what worktool did NOT write (a closed statement, not a question)" {
    run _adr4_definition
    assert_success
    refute_output --partial "是不是"
    assert_output --partial "不是由 worktool 寫出來的"
}

@test "ADR 0004 names every script that writes a user file: setup.sh and assemble.sh (home_record)" {
    run _adr4_guard_section
    assert_success
    refute_output --partial "只有 \`just box setup\`"
    assert_output --partial "script/box/setup.sh"
    assert_output --partial "script/box/assemble.sh"
    assert_output --partial "home_record"
    # ... and cites at least one assemble spec for the state-file write.
    run _adr4_citations
    assert_success
    assert_output --regexp "test/[a-z]+/assemble_spec\.bats"
}

@test "doc/contract.md, once it exists, links invariant 1 to this ADR's path" {
    # The index links this exact path, so the ADR file must keep it.
    assert [ -f "${REPO_ROOT}/doc/adr/0004-invariant-user-content.md" ]
    # Until #201 creates the contract there is nothing to link from (no
    # skip: a skipped case is not green); from then on the link must be there.
    local _contract="${REPO_ROOT}/doc/contract.md"
    if [[ -f "${_contract}" ]]; then
        run grep -F "adr/0004-invariant-user-content.md" "${_contract}"
        assert_success
    fi
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}
