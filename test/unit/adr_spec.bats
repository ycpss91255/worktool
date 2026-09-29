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
#   ADR 0005 (invariant 2, single source, issue #203) records an invariant.
#   It must carry the four sections #200 fixed for every invariant ADR, and
#   its "what guards it today" section must not overclaim: every spec case
#   it cites (`test/.../x_spec.bats`「case name」) must exist verbatim, and
#   the parts nothing guards yet are marked 待補. Written test-first: RED
#   while the ADR does not exist.
#   Codex round 1 on PR #251: the 待補 list must name EVERY lib/ or script/
#   file that hardcodes the box name `dev` (bench.sh was missing), and the
#   ADR must say the doc/contract.md index link is backfilled by #201.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    ADR_0002="${REPO_ROOT}/doc/adr/0002-box-owns-its-home.md"
    ADR_0005="${REPO_ROOT}/doc/adr/0005-invariant-single-source.md"
}

# The "## 目前由哪些機制或測試守住" section of ADR 0005, up to the next "## ".
_adr5_guard_section() {
    awk '/^## /{on = ($0 == "## 目前由哪些機制或測試守住")} on' "${ADR_0005}"
}

# Every `<spec path>`「<case name>」 citation of the guard section, one per
# line as "<path><TAB><name>". A line may cite several cases of one spec.
_adr5_citations() {
    local _line _path _rest _name _re="\`(test/[^\`]+\.bats)\`"
    while IFS= read -r _line; do
        [[ "${_line}" =~ ${_re} ]] || continue
        _path="${BASH_REMATCH[1]}" _rest="${_line}"
        while [[ "${_rest}" == *「*」* ]]; do
            _rest="${_rest#*「}"
            _name="${_rest%%」*}"
            _rest="${_rest#*」}"
            printf '%s\t%s\n' "${_path}" "${_name}"
        done
    done < <(_adr5_guard_section)
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

@test "ADR 0005 exists with the ADR header (title, status, discussion)" {
    assert [ -f "${ADR_0005}" ]
    run head -n 1 "${ADR_0005}"
    assert_output --regexp '^# 0005 '
    run grep -c -E '^- 狀態：已採納' "${ADR_0005}"
    assert_output "1"
    run grep -E '^- 討論：' "${ADR_0005}"
    assert_output --partial "#200"
    assert_output --partial "#203"
}

@test "ADR 0005 has the four invariant sections of #200, in order" {
    run grep -E '^## ' "${ADR_0005}"
    assert_success
    assert_line --index 0 "## 一句話"
    assert_line --index 1 "## 性質"
    assert_line --index 2 "## 為什麼固定"
    assert_line --index 3 "## 目前由哪些機制或測試守住"
}

@test "ADR 0005 cites at least one spec case and marks the unguarded parts 待補" {
    run _adr5_citations
    assert_success
    assert_line --regexp $'^test/[^[:space:]]+\\.bats\t.+$'
    run _adr5_guard_section
    assert_output --partial "待補"
}

@test "every spec case ADR 0005 cites exists verbatim as an @test in that spec" {
    local _path _name _missing=""
    assert [ -f "${ADR_0005}" ]
    while IFS=$'\t' read -r _path _name; do
        if ! grep -qF "@test \"${_name}\" {" "${REPO_ROOT}/${_path}"; then
            _missing+="${_path}: ${_name}"$'\n'
        fi
    done < <(_adr5_citations)
    assert_equal "${_missing}" ""
}

# Every lib/ or script/ file that hardcodes the box name `dev` as a value
# (`X="dev"`, `printf 'dev\n'`), one path per line. Comments are skipped.
_hardcoded_box_name_files() {
    grep -rlE "^[^#]*(=[\"']dev[\"']|printf 'dev\\\\n')" \
        --include='*.sh' "${REPO_ROOT}/lib" "${REPO_ROOT}/script" |
        sed "s|^${REPO_ROOT}/||" | sort
}

@test "ADR 0005 lists every file that hardcodes a second copy of the box name dev (codex round 1)" {
    local _file _missing=""
    run _hardcoded_box_name_files
    assert_success
    assert_line "lib/enter.sh"
    assert_line "script/box/bench.sh"
    while IFS= read -r _file; do
        _adr5_guard_section | grep -qF "\`${_file}\`" || _missing+="${_file}"$'\n'
    done < <(_hardcoded_box_name_files)
    assert_equal "${_missing}" ""
}

@test "ADR 0005 says the doc/contract.md invariant index link is backfilled by #201 (codex round 1)" {
    run grep -E '^- 索引：' "${ADR_0005}"
    assert_success
    assert_output --partial "doc/contract.md"
    assert_output --partial "#201"
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# --- ADR 0010: invariant 7 (black-box verifiable), issue #208 ---------------
#
# The ADR lists the specs that guard the invariant today. Each guard line
# names a spec file in backticks and one case in 「」; the file must exist and
# hold a @test with exactly that name, so the ADR cannot claim a guard that
# is not there (or survive a rename of it). Gaps are marked 待補.

_adr_0010() {
    printf '%s\n' "${REPO_ROOT}/doc/adr/0010-invariant-black-box-verifiable.md"
}

# The body of section "## $1" of ADR 0010 (up to the next "## ").
_adr_0010_section() {
    awk -v h="## $1" '$0 == h { on = 1; next } /^## / { on = 0 } on' "$(_adr_0010)"
}

# Check one guard line ($1): print "<file>: <case>" for a case that is
# missing, return 1 on a malformed line.
_adr_0010_check_guard() {
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

@test "ADR 0010 exists with the invariant title and the four sections in order" {
    run head -n 1 "$(_adr_0010)"
    assert_success
    assert_output "# 0010 不變量 7：對外承諾必須黑箱可驗，開發與正式使用走同一個入口"
    run grep -E '^## ' "$(_adr_0010)"
    assert_success
    assert_line --index 0 "## 一句話"
    assert_line --index 1 "## 性質"
    assert_line --index 2 "## 為什麼固定"
    assert_line --index 3 "## 目前由哪些機制或測試守住"
    assert_equal "${#lines[@]}" 4
}

@test "ADR 0010 names its discussion issues (#208, parent #200)" {
    run grep -E '^- 討論：' "$(_adr_0010)"
    assert_success
    assert_output --partial "#200"
    assert_output --partial "#208"
}

@test "every spec case ADR 0010 cites as a guard exists under that exact name" {
    local _bt=$'\x60' _line _missing="" _n=0
    while IFS= read -r _line; do
        _n=$((_n + 1))
        run _adr_0010_check_guard "${_line}"
        assert_success
        _missing+="${output}"
    done < <(_adr_0010_section "目前由哪些機制或測試守住" | grep -E "${_bt}test/[^${_bt}]*\.bats${_bt}")
    assert [ "${_n}" -ge 3 ]
    assert_equal "${_missing}" ""
}

@test "ADR 0010 marks the unguarded parts as 待補 instead of claiming them" {
    run _adr_0010_section "目前由哪些機制或測試守住"
    assert_success
    assert_output --partial "待補"
}

@test "ADR 0010 scopes the CI claim to the test gates and excludes build-image" {
    # codex round 1 on PR #255: the mechanism line said every CI gate runs
    # through just test, while the same ADR records that the build-image job
    # runs docker build directly. The claim must cover only the test gates
    # and name build-image as the exception.
    run bash -c 'grep -F ".github/workflows/ci.yml" | grep -E "^- CI "' \
        _ < <(_adr_0010_section "目前由哪些機制或測試守住")
    assert_success
    assert_equal "${#lines[@]}" 1
    refute_output --partial "每一個 gate"
    assert_output --partial "測試 gate"
    assert_output --partial "build-image"
    assert_output --partial "docker build"
}
