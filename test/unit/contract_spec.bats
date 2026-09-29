#!/usr/bin/env bats
# test/unit/contract_spec.bats - doc/contract.md shape guards (issue #201)
#
# WHAT THIS PROVES
#   doc/contract.md (the user-facing contract decided in #200) keeps the
#   shape the issue asks for:
#     - the six sections, in order;
#     - every promise ("- **...**" item) in sections 2-5 carries exactly one
#       "驗證：" line that names how it is verified or says 待驗
#       (invariant 7: a promise must be black-box verifiable);
#     - every test file a 驗證 line cites exists (no promise leans on a
#       spec that is not there);
#     - the invariant index lists the ten invariants in order, each linked
#       to its pre-assigned ADR file;
#     - the later decisions are reflected: the box owns its HOME (ADR 0002),
#       the latency verdict exit 3 (ADR 0003), tool config vs user config;
#     - doc/structure.md lists the file in its tree.
#   It checks shape and references, not the wording of each promise.
#
# Written test-first: RED before doc/contract.md exists, GREEN after.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    CONTRACT="${REPO_ROOT}/doc/contract.md"
}

# Body of the "## <n>. ..." section $1 (heading line excluded).
_section() {
    awk -v n="$1" '
        /^## / { on = ($0 ~ "^## " n "\\. "); next }
        on { print }
    ' "${CONTRACT}"
}

@test "doc/contract.md has the six sections of #201, in order" {
    run grep -E '^## [0-9]+\. ' "${CONTRACT}"
    assert_success
    assert_line --index 0 --regexp '^## 1\. 要解決的痛點'
    assert_line --index 1 --regexp '^## 2\. worktool 做的事'
    assert_line --index 2 --regexp '^## 3\. worktool 不做的事'
    assert_line --index 3 --regexp '^## 4\. 對使用者的承諾'
    assert_line --index 4 --regexp '^## 5\. 相容性承諾'
    assert_line --index 5 --regexp '^## 6\. 不變量索引'
    [ "${#lines[@]}" -eq 6 ]
}

@test "every promise in sections 2-5 has exactly one 驗證 line" {
    local n promises checks
    for n in 2 3 4 5; do
        promises="$(_section "${n}" | grep -cE '^- \*\*')"
        checks="$(_section "${n}" | grep -cE '^  - 驗證：')"
        echo "section ${n}: ${promises} promise(s), ${checks} 驗證 line(s)"
        [ "${promises}" -ge 1 ]
        [ "${promises}" -eq "${checks}" ]
    done
}

@test "every 驗證 line names a test, an acceptance item, or says 待驗" {
    local line seen=0
    while IFS= read -r line; do
        seen=$((seen + 1))
        echo "${line}"
        [[ "${line}" =~ test/|doc/acceptance\.md|待驗 ]]
    done < <(grep -E '^  - 驗證：' "${CONTRACT}")
    [ "${seen}" -ge 1 ]
}

@test "every test file a 驗證 line cites exists" {
    local path found=0
    while IFS= read -r path; do
        found=$((found + 1))
        echo "cited: ${path}"
        [ -f "${REPO_ROOT}/${path}" ]
    done < <(grep -E '^  - 驗證：' "${CONTRACT}" \
                 | grep -oE 'test/[A-Za-z0-9_/.-]+\.bats' | sort -u)
    [ "${found}" -ge 1 ]
}

@test "the invariant index links the ten invariants to their ADR files, in order" {
    local -a adr=(
        0004-invariant-user-content.md
        0005-invariant-single-source.md
        0006-invariant-host-box-separation.md
        0007-invariant-no-silent-failure.md
        0008-invariant-minimal-interface.md
        0009-invariant-idempotent.md
        0010-invariant-black-box-verifiable.md
        0011-invariant-minimal-host-deps.md
        0012-invariant-platform-neutral.md
        0013-invariant-compatibility.md
    )
    run bash -c "$(declare -f _section); CONTRACT=\"\$1\" _section 6 | grep -E '^[0-9]+\. '" _ "${CONTRACT}"
    assert_success
    [ "${#lines[@]}" -eq 10 ]
    local i
    for i in "${!adr[@]}"; do
        assert_line --index "${i}" --regexp "^$((i + 1))\. .*\(adr/${adr[i]}\)"
    done
}

@test "the contract reflects the box HOME (ADR 0002), exit 3 (ADR 0003) and tool config vs user config" {
    run cat "${CONTRACT}"
    assert_output --partial "adr/0002-box-owns-its-home.md"
    assert_output --partial "adr/0003-latency-gate-inconclusive.md"
    assert_output --partial "--home"
    assert_output --partial "tool config"
    assert_output --partial "user config"
    run grep -E '結束碼 .?3|exit 3' "${CONTRACT}"
    assert_success
}

@test "doc/structure.md lists doc/contract.md in its tree" {
    run sed -n '/^## 目錄結構/,/^## /p' "${REPO_ROOT}/doc/structure.md"
    assert_success
    assert_output --regexp '│   ├── contract\.md '
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}
