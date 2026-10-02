# #363：PR #406 第 1 輪修正證據

本輪只修正 PR 說明的 issue 關閉關聯。移除 `Closes #363`，保留
`Part of #363` 與原有驗收條件；不合併 PR、不關閉 #363。
#363 要等修正納入 #157 且該 head 的兩架構 verify-all GREEN 才能結案。

## 單一行為與 RED／GREEN

行為：PR #406 保留 #363 的部分工作關聯，但不會在合併時自動關閉 #363。
測試使用 `gh pr view 406 --repo ycpss91255/worktool --json body,closingIssuesReferences`
擷取的真實 GitHub 回應，存入 `.agents/state/406-description.json`。
沒有以 fixture 替代遠端關閉關聯。

先建立以下單一 spec，再修改 PR 說明；兩次皆透過
`just test unit test/unit/pr_406_description_spec.bats` 在 Docker 執行。

```bash
#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"

@test "PR 406 keeps issue 363 open until milestone acceptance" {
    run jq -e '
        (.body | split("\n") | index("Part of #363") != null) and
        (.body | split("\n") | index("Closes #363") == null) and
        ([.closingIssuesReferences[] | select(.number == 363)] | length == 0)
    ' "${REPO_ROOT}/.agents/state/406-description.json"
    assert_success
}
```

RED（exit 1）：

```text
not ok 1 PR 406 keeps issue 363 open until milestone acceptance
# status : 1
# output : false
```

原始回應的本文含關閉宣告，`closingIssuesReferences` 包含 #363。
移除關閉宣告後，GitHub 首次回應仍帶舊關聯，spec 繼續失敗；
重新擷取後才取得空陣列，沒有放寬斷言。

GREEN（exit 0）：

```text
1..1
ok 1 PR 406 keeps issue 363 open until milestone acceptance
[ci] unit bats OK
```

修正後的遠端回應保留 `Part of #363`、無關閉宣告，
`closingIssuesReferences` 為 `[]`；另查詢 #363 的 state 為 `OPEN`。
PR 說明只刪除關閉宣告，其餘內容保留。

這是一次性遠端中繼資料驗證。spec 原文保存在本文件，
執行用 spec 移至被忽略的 `.agents/state/406-description-spec.txt`，
避免 CI 的產品測試依賴本機快照或即時 GitHub 資料。
完整 RED／GREEN log 留在本 worktree 的 `.agents/state/406-review-round-1-*.log`。

## 推送前 gates

`just test lint`、`just test changed` 均以前景阻塞方式在 Docker 執行。
結果記錄於本輪 PR 留言；沒有執行完整 tier，也沒有在 host 執行 bats。
