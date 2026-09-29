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

# --- ADR 0013: invariant 10, compatibility (issue #211) ----------------------
#
# The invariant ADRs (parent #200) share four sections, and the last one
# lists what guards the invariant today. That list must not overclaim:
# every spec case it cites (a `test/...bats` path followed by 「case name」
# on the same bullet) must exist verbatim in that spec, and the gaps are
# marked 待補 instead of being left out. Written test-first: RED while the
# ADR does not exist.

_adr_0013() {
    printf '%s\n' "${REPO_ROOT}/doc/adr/0013-invariant-compatibility.md"
}

# Body of the "## $1" section of ADR 0013 (heading line excluded).
_adr_0013_section() {
    awk -v h="## $1" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$(_adr_0013)"
}

@test "ADR 0013 has the four invariant sections, in order" {
    run grep -E '^## ' "$(_adr_0013)"
    assert_success
    assert_output "$(printf '%s\n' '## 一句話' '## 性質' '## 為什麼固定' '## 目前由哪些機制或測試守住')"
}

@test "ADR 0013 states invariant 10 as decided in #200 and links the issues" {
    run _adr_0013_section 一句話
    assert_success
    assert_output --partial "同一個大版號內不破壞原本的用法"
    run grep -E '^- 討論：.*#211.*#200' "$(_adr_0013)"
    assert_success
}

@test "ADR 0013 marks the missing guards 待補" {
    run _adr_0013_section 目前由哪些機制或測試守住
    assert_success
    assert_output --partial "待補"
}

@test "every spec case ADR 0013 cites as a guard exists verbatim in that spec" {
    local cited=0 line spec name
    local cite_re="^- \`(test/[^\`]+\\.bats)\`"
    while IFS= read -r line; do
        [[ "${line}" =~ ${cite_re} ]] || continue
        spec="${BASH_REMATCH[1]}"
        assert [ -f "${REPO_ROOT}/${spec}" ]
        while IFS= read -r name; do
            [[ -n "${name}" ]] || continue
            cited=$((cited + 1))
            run grep -cF "@test \"${name}\" {" "${REPO_ROOT}/${spec}"
            assert_output 1
        done < <(grep -oE '「[^」]+」' <<<"${line}" | sed -E 's/^「//; s/」$//')
    done < <(_adr_0013_section 目前由哪些機制或測試守住)
    # The section cites at least one case, so the loop above checked something.
    assert [ "${cited}" -gt 0 ]
}
