#!/usr/bin/env bats
# test/unit/adr_spec.bats - shared ADR wording guards

load "${BATS_TEST_DIRNAME}/../helper/common"

_invariant_section() {
    awk -v heading="## $2" '
        $0 == heading { found = 1; next }
        /^## / { if (found) exit }
        found { print }
        END { if (!found) exit 1 }
    ' "$1"
}

_invariant_adr_files() {
    find "${REPO_ROOT}/doc/adr" -maxdepth 1 -type f \
        -name '*-invariant-*.md' -print | sort
}

_check_invariant_sections() {
    local _actual _expected _heading _body
    _expected="$(printf '%s\n' '## 一句話' '## 性質' '## 為什麼固定' \
        '## 目前由哪些機制或測試守住')"
    _actual="$(grep -E '^## ' "$1")" || return 1
    if [[ "${_actual}" != "${_expected}" ]]; then
        printf '%s: invariant sections differ\n' "$1"
        return 1
    fi
    for _heading in 一句話 性質 為什麼固定 目前由哪些機制或測試守住; do
        _body="$(_invariant_section "$1" "${_heading}")" || return 1
        if ! grep -q '[^[:space:]]' <<<"${_body}"; then
            printf '%s: empty section: %s\n' "$1" "${_heading}"
            return 1
        fi
    done
}

_invariant_spec_paths() {
    grep -oE 'test/(unit|integration|system|acceptance)/[A-Za-z0-9_/-]+_spec\.bats' "$1" |
        sort -u
}

_check_invariant_spec_paths() {
    local _path _missing=0
    while IFS= read -r _path; do
        [[ -f "${REPO_ROOT}/${_path}" ]] && continue
        printf '%s: missing cited spec: %s\n' "$1" "${_path}"
        _missing=1
    done < <(_invariant_spec_paths "$1")
    return "${_missing}"
}

_check_invariant_pending() {
    _invariant_section "$1" 目前由哪些機制或測試守住 | grep -q '待補'
}

@test "every invariant ADR follows the shared format and cites existing guards" {
    local _adr _count=0
    while IFS= read -r _adr; do
        _count=$((_count + 1))
        run _check_invariant_sections "${_adr}"
        assert_success
        run _check_invariant_spec_paths "${_adr}"
        assert_success
        run _check_invariant_pending "${_adr}"
        assert_success
    done < <(_invariant_adr_files)
    assert [ "${_count}" -gt 0 ]
}

@test "the shared invariant check rejects an ADR with a missing section" {
    run _check_invariant_sections \
        "${BATS_TEST_DIRNAME}/fixture/adr/9999-invariant-missing-section.md"
    assert_failure
    assert_output --partial "invariant sections differ"
}

setup() {
    ADR_0002="${REPO_ROOT}/doc/adr/0002-box-owns-its-home.md"
}

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
    run grep -E "各自改寫" "${ADR_0002}"
    assert_success
    refute_output --partial "架構圖"
    run grep -c "架構圖.*同一個 PR" "${ADR_0002}"
    assert_success
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}
