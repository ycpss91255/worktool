#!/usr/bin/env bats
# test/unit/contract_spec.bats - doc/contract.md shape guards (issue #201)
#
# WHAT THIS PROVES
#   doc/contract.md (the user-facing contract decided in #200) keeps the
#   shape the issue asks for:
#     - the six sections, in order;
#     - every promise ("- **...**" item) in sections 2-5 carries exactly one
#       "驗證：" line of its own (counted per promise, so one promise with
#       two cannot hide a neighbour with none) that names how it is
#       verified or says 待驗 (invariant 7: a promise must be black-box
#       verifiable);
#     - every test file a 驗證 line cites exists (no promise leans on a
#       spec that is not there);
#     - the invariant index lists the ten invariants in order, each naming
#       the issue that will write its ADR (#202-#211), and every relative
#       link in the page resolves to a file that exists;
#     - the page does not over-claim: it does not say every promise is
#       verified while some are 待驗, and it does not present the selfcheck
#       acceptance spec (which runs the script directly) as going through just;
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

# Reads a section body on stdin; prints "<count> <promise>" for every
# promise ("- **...**" item): how many "  - 驗證：" lines sit under it
# before the next top-level item.
_checks_per_promise() {
    awk '
        /^- / { if (on) print c, t; on = ($0 ~ /^- \*\*/); c = 0; t = $0; next }
        on && /^  - 驗證：/ { c++ }
        END { if (on) print c, t }
    '
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

@test "each promise in sections 2-5 carries its own single 驗證 line" {
    # Counted per promise, not per section: a promise with two 驗證 lines
    # must not cover for a neighbour with none.
    local n
    for n in 2 3 4 5; do
        run bash -c "$(declare -f _section _checks_per_promise); CONTRACT=\"\$1\" _section \"\$2\" | _checks_per_promise" _ "${CONTRACT}" "${n}"
        assert_success
        echo "section ${n}:"
        echo "${output}"
        [ "${#lines[@]}" -ge 1 ]
        refute_line --regexp '^([^1]|1[^ ])'
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

@test "the invariant index lists the ten invariants, in order, each naming its ADR issue" {
    local -a issue=(202 203 204 205 206 207 208 209 210 211)
    run bash -c "$(declare -f _section); CONTRACT=\"\$1\" _section 6 | grep -E '^[0-9]+\. '" _ "${CONTRACT}"
    assert_success
    [ "${#lines[@]}" -eq 10 ]
    local i
    for i in "${!issue[@]}"; do
        assert_line --index "${i}" --regexp "^$((i + 1))\. .*#${issue[i]}"
    done
}

@test "invariant 2 links to its merged ADR 0005" {
    run grep -E '^2\. ' "${CONTRACT}"
    assert_success
    assert_output --partial "[ADR 0005](adr/0005-invariant-single-source.md)"
    [ -f "${REPO_ROOT}/doc/adr/0005-invariant-single-source.md" ]
}

@test "invariant 3 links to its merged ADR 0006" {
    run grep -E '^3\. ' "${CONTRACT}"
    assert_success
    assert_output --partial "[ADR 0006](adr/0006-invariant-host-box-separation.md)"
    [ -f "${REPO_ROOT}/doc/adr/0006-invariant-host-box-separation.md" ]
}

@test "invariant 5 links to its merged ADR 0008" {
    run grep -E '^5\. ' "${CONTRACT}"
    assert_success
    assert_output --partial "[ADR 0008](adr/0008-invariant-minimal-interface.md)"
    [ -f "${REPO_ROOT}/doc/adr/0008-invariant-minimal-interface.md" ]
}

@test "invariant 7 links to its merged ADR 0010" {
    run grep -E '^7\. ' "${CONTRACT}"
    assert_success
    assert_output --partial "[ADR 0010](adr/0010-invariant-black-box-verifiable.md)"
    [ -f "${REPO_ROOT}/doc/adr/0010-invariant-black-box-verifiable.md" ]
}

@test "invariant 8 links to its merged ADR 0011" {
    run grep -E '^8\. ' "${CONTRACT}"
    assert_success
    assert_output --partial "[ADR 0011](adr/0011-invariant-minimal-host-deps.md)"
    [ -f "${REPO_ROOT}/doc/adr/0011-invariant-minimal-host-deps.md" ]
}

@test "invariant 9 links to its merged ADR 0012" {
    run grep -E '^9\. ' "${CONTRACT}"
    assert_success
    assert_output --partial "[ADR 0012](adr/0012-invariant-platform-neutral.md)"
    [ -f "${REPO_ROOT}/doc/adr/0012-invariant-platform-neutral.md" ]
}

@test "invariant 10 links to its merged ADR 0013" {
    run grep -E '^10\. ' "${CONTRACT}"
    assert_success
    assert_output --partial "[ADR 0013](adr/0013-invariant-compatibility.md)"
    [ -f "${REPO_ROOT}/doc/adr/0013-invariant-compatibility.md" ]
}

@test "every relative link in doc/contract.md resolves to an existing file" {
    local target found=0
    while IFS= read -r target; do
        found=$((found + 1))
        echo "link: ${target}"
        [ -e "${REPO_ROOT}/doc/${target%%#*}" ]
    done < <(grep -oE '\]\([^)]+\)' "${CONTRACT}" \
                 | sed -E 's/^\]\((.*)\)$/\1/' | grep -vE '^[a-z]+:' | sort -u)
    [ "${found}" -ge 1 ]
}

@test "the contract does not claim every promise is verified while some are 待驗" {
    run grep -cE '^  - 驗證：.*待驗' "${CONTRACT}"
    assert_success
    [ "${output}" -ge 1 ]
    run grep -E '每條承諾都有' "${CONTRACT}"
    assert_failure
}

@test "the selfcheck acceptance spec is not cited as going through just" {
    # m2_selfcheck_spec.bats runs script/test/selfcheck.sh directly, so the
    # contract must not present it as a check through the public entry.
    run grep -E '^  - 驗證：.*m2_selfcheck_spec\.bats' "${CONTRACT}"
    assert_success
    refute_output --regexp 'm2_selfcheck_spec\.bats[^；。]*(公開入口|just test selfcheck)'
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

@test "the contract describes tool config placement without calling it user entry" {
    run _section 2
    assert_success
    assert_output --partial "tool config 要到 M5 才開始放進盒子 HOME"
    assert_output --partial "tool config 從 M5 起才放進盒子 HOME"
    refute_output --regexp 'tool config[^。；，]*進盒([，。]|$)'
    assert_output --partial "終端進盒設定（\`just box setup\`）"
}

@test "doc/structure.md describes the invariant index as naming ADR issues, not linking ADRs" {
    # The index names the issue that will write each ADR (#202-#211) until
    # those ADRs merge; the tree entries must not say it links ADR files.
    run grep -E '(contract\.md|contract_spec\.bats) ' "${REPO_ROOT}/doc/structure.md"
    assert_success
    [ "${#lines[@]}" -eq 2 ]
    refute_output --regexp 'ADR 索引|連到指定 ADR'
    assert_line --regexp '├── contract\.md .*#202-#211'
    assert_line --regexp '├── contract_spec\.bats .*#202-#211'
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "#724: structure directory tree includes the M3 helpers, evidence and unit fixtures" {
    local tree section name path
    tree="$(sed -n '/^## 目錄結構/,/^```$/p' "${REPO_ROOT}/doc/structure.md")"
    section="$(sed -n '/^├── lib\//,/^├── box\//p' <<<"${tree}")"
    for name in config_backup.sh distrobox_manager.sh guard.sh verify_run.sh realbox_interrupt.sh; do
        [[ "${section}" == *"── ${name} "* ]]
    done
    section="$(sed -n '/^│   └── helper\//,/^├── dockerfile\//p' <<<"${tree}")"
    for name in diagnostics.bash interrupt_load.bash realbox_window.bash; do
        [[ "${section}" == *"── ${name} "* ]]
    done
    section="$(sed -n '/^├── doc\//,/^├── .agents\//p' <<<"${tree}")"
    [[ "${section}" == *'── evidence/ '* ]]
    section="$(sed -n '/^│   │   └── fixture\//,/^│   ├── matrix\//p' <<<"${tree}")"
    while IFS= read -r path; do
        name="${path##*/}"
        [[ "${section}" == *"── ${name} "* ]]
    done < <(find "${REPO_ROOT}/test/unit/fixture" -type f | sort)
}

@test "#724: structure describes guard as fail-closed status primitives" {
    run grep -F '── guard.sh ' "${REPO_ROOT}/doc/structure.md"
    assert_success
    assert_output --partial '失敗封閉的狀態原語'
    assert_output --partial '區分不存在與無法判定'
    refute_output --partial '驗收前置檢查與拒絕條件'
}

_check_evidence_tree() {
    local root="$1" files
    files=$(cd "${root}/doc/evidence" && find . -type f | sed 's|^./||' | sort)
    jq -ner --arg files "$files" --rawfile structure "${root}/doc/structure.md" '
        ($structure | split("\n") | map(select(contains("── evidence/"))) | .[0]) as $description |
        ($structure | split("── evidence/")[1] | split("\n│   ├── ")[0] |
            split("\n")[1:] | map(capture("^(?<indent>(?:│   |    )*)[├└]── (?<name>[^ ]+)"))) as $entries |
        (reduce $entries[] as $entry ({dirs: [], files: []};
            (($entry.indent | length) / 4 - 2) as $depth |
            .dirs = .dirs[:$depth] |
            if ($entry.name | endswith("/")) then .dirs += [$entry.name | rtrimstr("/")]
            else .files += [(.dirs + [$entry.name]) | join("/")] end) | .files | sort) as $documented |
        if $documented == ($files | split("\n") | sort) then $description
        else error("evidence tree: documented files differ from directory contents") end'
}

@test "#724: evidence tree description distinguishes existing contents from new review policy" {
    run _check_evidence_tree "${REPO_ROOT}"
    assert_success
    assert_output --partial '驗收檢查程式、fixture 與證據'
    assert_output --partial '既有 review 紀錄'
    assert_output --partial '新增審查紀錄改放 PR 留言或 .agents/state/'
}

@test "#724: evidence tree check rejects removed or undocumented contents" {
    local copy="${BATS_TEST_TMPDIR}/copy" path
    mkdir -p "${copy}/doc"
    cp "${REPO_ROOT}/doc/structure.md" "${copy}/doc/"
    cp -R "${REPO_ROOT}/doc/evidence" "${copy}/doc/"
    run _check_evidence_tree "${copy}"
    assert_success
    while IFS= read -r path; do
        rm "${copy}/doc/evidence/${path}"
        run _check_evidence_tree "${copy}"
        assert_failure
        cp "${REPO_ROOT}/doc/evidence/${path}" "${copy}/doc/evidence/${path}"
    done < <(cd "${REPO_ROOT}/doc/evidence" && find . -type f | sed 's|^./||' | sort)
    for path in unexpected.txt negative/unexpected.json; do
        touch "${copy}/doc/evidence/${path}"
        run _check_evidence_tree "${copy}"
        assert_failure
        rm "${copy}/doc/evidence/${path}"
    done
}

@test "#728: user config symlinks are delivered and cite preservation checks" {
    run _section 3
    assert_success
    assert_output --partial "以 symlink 從 host HOME 帶進盒子 HOME"
    assert_output --partial "test/integration/assemble_spec.bats"
    refute_output --partial "尚未實作"
    refute_output --partial "#199 落地時"
    run cat "${REPO_ROOT}/doc/adr/0004-invariant-user-content.md"
    assert_success
    assert_output --partial "test/unit/link_spec.bats"
    refute_output --partial "待補，由 #199 實作"
}

@test "#728: verify exit 3 is unavailable or inconclusive with verification references" {
    run bash -c 'grep -A1 "^- \*\*永不靜默失敗" "$1"' _ "${CONTRACT}"
    assert_success
    assert_output --regexp "just verify.*\`3\`.*UNAVAILABLE.*未判定"
    assert_output --partial "test/unit/verify_all_spec.bats"
    assert_output --partial "test/unit/verify_gate_spec.bats"
}

@test "#728: latency index note cites the settled ADR 0003 decision" {
    run _section 6
    assert_success
    assert_output --regexp '進盒 < 300 ms.*已.*ADR 0003'
    refute_output --partial "待 #181 定案"
}
