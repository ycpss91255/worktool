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

# --- ADR 0006: invariant 3, host and box never interfere (issue #204) --------

ADR_0006_NAME="0006-invariant-host-box-separation.md"

# Section "## $1" of ADR 0006, heading excluded, up to the next "## ".
_adr_0006_section() {
    sed -n "/^## $1\$/,/^## /p" "${REPO_ROOT}/doc/adr/${ADR_0006_NAME}" | sed '1d;/^## /d'
}

@test "#204: ADR 0006 has the four invariant sections, each non-empty" {
    local _s
    assert [ -f "${REPO_ROOT}/doc/adr/${ADR_0006_NAME}" ]
    for _s in 一句話 性質 為什麼固定 目前由哪些機制或測試守住; do
        run _adr_0006_section "${_s}"
        assert_success
        assert_output --regexp '[^[:space:]]'
    done
}

@test "#204: ADR 0006 names ADR 0002 as the mechanism and #179 for tmux isolation" {
    run _adr_0006_section 目前由哪些機制或測試守住
    assert_success
    assert_output --partial "0002-box-owns-its-home.md"
    assert_output --partial "#179"
}

@test "#204: every spec file ADR 0006 cites as a guard exists in the repo" {
    local _f
    run grep -oE 'test/(unit|integration|system|acceptance)/[a-z0-9_]+_spec\.bats' \
        "${REPO_ROOT}/doc/adr/${ADR_0006_NAME}"
    assert_success
    for _f in "${lines[@]}"; do
        assert [ -f "${REPO_ROOT}/${_f}" ]
    done
}

@test "#204: ADR 0006 marks what no test guards yet as 待補" {
    run _adr_0006_section 目前由哪些機制或測試守住
    assert_success
    assert_output --partial "待補"
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}
