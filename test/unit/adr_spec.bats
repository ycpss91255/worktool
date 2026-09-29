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
#   ADR 0012 (invariant 9, correctness is not tied to one platform, issue
#   #210) has the four sections every invariant ADR carries, and every
#   guard it cites under "目前由哪些機制或測試守住" is checkable: each cited
#   spec file exists and each case name quoted as 「...」 is a real
#   `@test` of that file, so the ADR cannot claim a guard that is not there
#   (or silently keep one that was renamed away). The Ubuntu 24.04 leg is
#   not built yet (#148) and must be marked 待補.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    ADR_0002="${REPO_ROOT}/doc/adr/0002-box-owns-its-home.md"
    ADR_0012="${REPO_ROOT}/doc/adr/0012-invariant-platform-neutral.md"
}

# Body of the "## $2" section of ADR file $1 (heading line excluded).
_section() {
    awk -v h="## $2" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$1"
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

@test "ADR 0012 has the four invariant ADR sections" {
    local _h
    [[ -f "${ADR_0012}" ]]
    for _h in "一句話" "性質" "為什麼固定" "目前由哪些機制或測試守住"; do
        run grep -cxF "## ${_h}" "${ADR_0012}"
        assert_success
        assert_output 1
    done
}

@test "ADR 0012 cites the amd64/arm64 CI matrix spec as a guard" {
    run _section "${ADR_0012}" "目前由哪些機制或測試守住"
    assert_success
    assert_output --partial "test/unit/ci_yml_spec.bats"
}

@test "ADR 0012: every cited spec file exists and every quoted case name is a real @test in it" {
    local _line _file _name _n=0
    while IFS= read -r _line; do
        _file="$(grep -oE 'test/[A-Za-z0-9_/.-]+\.bats' <<<"${_line}" | head -n 1)"
        [[ -n "${_file}" ]] || continue
        [[ -f "${REPO_ROOT}/${_file}" ]] || fail "cited spec missing: ${_file}"
        while IFS= read -r _name; do
            grep -qF "@test \"${_name}\" {" "${REPO_ROOT}/${_file}" \
                || fail "no such case in ${_file}: ${_name}"
            _n=$((_n + 1))
        done < <(grep -oE '「[^」]+」' <<<"${_line}" | sed -e 's/^「//' -e 's/」$//')
    done < <(_section "${ADR_0012}" "目前由哪些機制或測試守住")
    (( _n > 0 )) || fail "ADR 0012 quotes no case name at all"
}

@test "ADR 0012 marks the Ubuntu 24.04 leg as 待補 and names #148" {
    run _section "${ADR_0012}" "目前由哪些機制或測試守住"
    assert_success
    assert_line --regexp '24\.04.*待補.*#148|24\.04.*#148.*待補'
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}
