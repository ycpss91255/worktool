#!/usr/bin/env bats

load '../helper/common'

_assert_evidence_doc() {
    local section checks cells verdict tdd
    section="$(sed -n '/^- 外部證據：/,/^- TDD 證據：/p' "$1")"
    [[ "${section}" == *"just verify evidence 6.1"* && "${section}" == *"just verify evidence 6.2"* && "${section}" == *"just verify evidence 6.3"* ]] || return 1
    [[ "${section}" == *"缺少必要工具回 \`rc=3\`"* ]] || return 1
    tdd="$(sed -n '/^- TDD 證據：/,/^- \[ \] 1\.1/p' "$1")"
    [[ "${tdd}" == *"just verify gate 2.2"* && "${tdd}" == *"不替代 gate 的集合判準"* ]] || return 1
    checks="$(sed -n '/^  - 6\.1：/,/^  - 6\.2：/p' <<<"${section}" | sed '$d')"
    cells="$(sed -n '/^  - 6\.2：/,/^  - 6\.3：/p' <<<"${section}" | sed '$d')"
    verdict="$(sed -n '/^  - 6\.3：/,$p' <<<"${section}")"
    [[ "${checks}" == *"checks 非空且全部 pass"* && "${checks}" == *"恰有一行 \`Closes #\` 指向對應 issue，十個 issue 互異"* && "${checks}" == *"\`distinct=10\`"* ]] || return 1
    [[ "${checks}" == *"相異 check 名稱數均大於零且相等，兩組名稱不重疊"* ]] || return 1
    [[ "${cells}" == *"#22 須有 \`median=<數字> ms\`（可含小數）與「維持 docker + 預設 runc」，#148 須有"* ]] || return 1
    [[ "${cells}" == *"「只用 LTS」與「ubuntu-24.04-arm」，#21 須有「預設 = 直接進盒」與「印 log」"* ]] || return 1
    [[ "${cells}" == *"留言查詢涵蓋所有分頁"* && "${cells}" == *"\`default-enter\`、\`log\`"* ]] || return 1
    [[ "${cells}" == *"必須為 \`1\`。\`0\` 表示未找到決議，\`no-comments\` 表示沒有該留言，"* ]] || return 1
    [[ "${cells}" == *"\`gh-failed\`／\`grep-failed\` 表示查詢／搜尋失敗，均不通過。"* ]] || return 1
    [[ "${verdict}" == *"的 #152、#153、#154、#155 分別由 issue #163、#164、#162、#161"* ]] || return 1
    [[ "${verdict}" == *"與修復 PR #166、#165、#169、#168 接續，修復 PR 的最後判決需可合併"* ]] || return 1
    [[ "${verdict}" == *"原 PR 的最後判決須為 \`blocked\`"* && "${verdict}" == *"follow-up issue；查詢回傳的已合併修復 PR 中，恰有一個"* ]] || return 1
    [[ "${verdict}" == *"唯一性限於回傳集合"* ]] || return 1
    [[ "${verdict}" == *"且須符合上述固定配對。四個 follow-up 與四個修復 PR 各不相同"* ]] || return 1
    [[ "${verdict}" == *"\`distinct-follow-ups=4\`、\`distinct-fix-prs=4\`"* ]] || return 1
    [[ "${verdict}" == *"合法修復鏈可包含 \`blocked\`；必要判決為 \`blocked\` 或 \`NOT\`、鏈為 \`BAD\`，"* ]] || return 1
    [[ "${verdict}" == *"或出現 \`gh-failed\`、\`no-codex\`、\`no-follow-up\`、"* ]] || return 1
    [[ "${verdict}" == *"\`no-claude-comment\`、\`grep-failed\`、\`bad-fix-pr\` 均不通過。"* ]]
}

@test "M3 evidence documentation states the cell and failure criteria" {
    run _assert_evidence_doc "${REPO_ROOT}/doc/acceptance.md"
    assert_success
}

@test "M3 evidence documentation guard rejects misplaced or reversed criteria" {
    local doc="${BATS_TEST_TMPDIR}/acceptance.md"
    sed 's/唯一性限於回傳集合/唯一性涵蓋全部 PR/' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_evidence_doc "${doc}"
    assert_failure
    sed 's/且須符合上述固定配對/不須符合上述固定配對/' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_evidence_doc "${doc}"
    assert_failure
    sed 's/#148 須有/#149 須有/' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_evidence_doc "${doc}"
    assert_failure
    sed 's/#163、#164、#162、#161/#164、#163、#162、#161/' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_evidence_doc "${doc}"
    assert_failure
    sed 's/指向對應 issue，十個 issue 互異/可指向任一 issue/' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_evidence_doc "${doc}"
    assert_failure
    sed 's/兩組名稱不重疊/兩組名稱可重疊/' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_evidence_doc "${doc}"
    assert_failure
    sed 's/只用 LTS/支援所有版本/' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_evidence_doc "${doc}"
    assert_failure
    sed "s/\`distinct-fix-prs=4\`/\`distinct-fix-prs=1\`/" "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_evidence_doc "${doc}"
    assert_failure
    sed "s/必須為 \`1\`/至少為 \`1\`/" "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_evidence_doc "${doc}"
    assert_failure
    sed "s/\`no-follow-up\`/missing/; /  - 6\.2：/a\\    \`no-follow-up\`" "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_evidence_doc "${doc}"
    assert_failure
    sed 's/合法修復鏈可包含/合法修復鏈不能包含/' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_evidence_doc "${doc}"
    assert_failure
    sed 's/均不通過/均通過/g' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_evidence_doc "${doc}"
    assert_failure
    sed "/必須為 \`1\`/d; /  - 6\.3：/a\\    必須為 \`1\`。\`0\` 表示未找到決議，\`no-comments\` 表示沒有該留言，" "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_evidence_doc "${doc}"
    assert_failure
}

_assert_tdd_negative_docs() {
    local doc
    doc="$(cat "$1")"
    [[ "${doc}" == *"\`just verify gate 2.4\` 每次執行時以 \`tdd.awk\` 檢查下列兩個負向 fixture"* ]] || return 1
    [[ "${doc}" == *"各例必須回 exit 1 並印出預期的拒絕判決，若接受負例或輸出不符則驗收失敗"* ]]
}

@test "TDD evidence explains each live negative fixture and rejects a false acceptance claim" {
    local doc="${BATS_TEST_TMPDIR}/README.md"
    run _assert_tdd_negative_docs "${REPO_ROOT}/doc/evidence/README.md"
    assert_success
    sed 's/若接受負例或輸出不符則驗收失敗/接受負例也算通過/' "${REPO_ROOT}/doc/evidence/README.md" >"${doc}"
    run _assert_tdd_negative_docs "${doc}"
    assert_failure
    sed 's/每次執行時/偶爾/' "${REPO_ROOT}/doc/evidence/README.md" >"${doc}"
    run _assert_tdd_negative_docs "${doc}"
    assert_failure
}

@test "TDD evidence documents the gate entry and direct checker scope" {
    run cat "${REPO_ROOT}/doc/evidence/README.md"
    assert_success
    assert_output --partial 'just verify gate 2.2'
    assert_output --partial '直接執行只判斷指定輸入，不替代 gate 的完整集合判準'
    refute_output --partial '現行入口是'
    run cat "${REPO_ROOT}/doc/evidence/tdd.sh"
    assert_success
    assert_output --partial 'just verify gate 2.2'
    assert_output --partial 'ordered result set'
}
