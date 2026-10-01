# Issue tracker：GitHub

本 repo 的 issue 與 spec 都放在 GitHub `ycpss91255/worktool`。所有操作一律用 `gh` CLI。整體設計見 `doc/design.md`、對外介面見 `doc/structure.md`、驗收見 `doc/acceptance.md`。

## 為什麼每個 `gh` 都明寫 `-R`

`gh` 不帶 `-R` 時會靠當下目錄的 remote 推出目標 repo：推得出來也是推測，換個目錄、worktree 或 submodule 就換了答案，有 fork 的 remote 時還會打到 fork。這在 worktool 發生過：在 initialization 的目錄下跑 `gh issue lock <n>`，鎖到的是 initialization 同編號的 issue。所以慣例是**每個指令都明寫 `-R ycpss91255/worktool`**，讓指令自己說出目標，跟從哪裡執行無關。

## 慣例

- **建立 issue**：`gh issue create -R ycpss91255/worktool --title "..." --body-file <檔> --label <標籤> --milestone <M>`（不屬於任何 milestone 時拿掉 `--milestone`，改在本文寫一行 `milestone: 無`，見下一條）。
- **milestone 表態**（#266）：新開的 issue 屬於某個 milestone 就掛對應的 M（`--milestone <名稱>` 或 `-m <名稱>`）；不屬於任何 milestone 就不掛，並在本文寫一行 `milestone: 無`。兩者必須擇一，都沒有或同時出現都會被 `enforce_issue_milestone` hook 擋下（exit 2）；包在 `bash -c`／`eval` 裡開 issue 也一樣算。hook 只看有沒有表態，不檢查名稱對不對（不存在的名稱 gh 自己會拒絕），也不替你判斷該掛哪一個；編輯既有 issue、開 PR 不受影響。
- **讀 issue**：`gh issue view <number> -R ycpss91255/worktool --comments`；需要時用 `jq` 過濾留言，並一併抓標籤。
- **列 issue**：`gh issue list -R ycpss91255/worktool --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`，視情況加 `--label`、`--state`、`--milestone`。
- **留言**：`gh issue comment <number> -R ycpss91255/worktool --body-file <檔>`
- **加／移標籤**：`gh issue edit <number> -R ycpss91255/worktool --add-label "..."` ／ `--remove-label "..."`
- **關閉**：先留言再關，分兩步：`gh issue comment <number> -R ycpss91255/worktool --body-file <檔>`，再 `gh issue close <number> -R ycpss91255/worktool`（close 帶 `--comment` 會被 `enforce_gh_body_file` hook 擋下）。

## 追蹤結構

- epic 是 #1。每個 milestone 對應一個 GitHub Milestone 與一個 parent issue，parent 底下以 GitHub sub-issue 掛多個 sub-issue。
- 一個 sub-issue 對一個 PR；PR 掛在對應的 Milestone 下。
- milestone 的人類驗收結果記在該 milestone 的驗收 PR 上，不記在 parent issue。

## 語言與內容

- issue、PR、留言一律用中文（指令、識別字、檔名保留原文）；不用 emoji。
- **設計決議寫進 issue 本文**（編輯 body），不是只留在對話或留言裡；留言只放討論過程，定案後回頭更新本文。
- 遇到需要維護者拍板的問題（設計取捨、契約要不要改、方案 A 或 B），貼 `needs-decision`，不要貼 `needs-info`；`needs-info` 只用在等回報者補資料。

## Pull request 當作需求來源

**PRs as a request surface: no.** _（若本 repo 把外部 PR 當功能需求，改成 `yes`；`/triage` 會讀這個旗標。）_

設為 `yes` 時，PR 走跟 issue 一樣的標籤與狀態，改用 `gh pr` 對應指令：

- **讀 PR**：`gh pr view <number> -R ycpss91255/worktool --comments`，diff 用 `gh pr diff <number> -R ycpss91255/worktool`。
- **列外部 PR 做 triage**：`gh pr list -R ycpss91255/worktool --state open --json number,title,body,labels,author,authorAssociation,comments`，只留 `authorAssociation` 為 `CONTRIBUTOR`、`FIRST_TIME_CONTRIBUTOR`、`NONE` 的（丟掉 `OWNER`／`MEMBER`／`COLLABORATOR`）。
- **留言**：`gh pr comment <number> -R ycpss91255/worktool --body-file <檔>`
- **加／移標籤**：`gh pr edit <number> -R ycpss91255/worktool --add-label "..."` ／ `--remove-label "..."`
- **關閉**：先 `gh pr comment <number> -R ycpss91255/worktool --body-file <檔>`，再 `gh pr close <number> -R ycpss91255/worktool`。

GitHub 的 issue 與 PR 共用同一個編號空間，光看 `#42` 分不出是哪種：先 `gh pr view 42 -R ycpss91255/worktool`，失敗再 `gh issue view 42 -R ycpss91255/worktool`。

## 當 skill 說「publish to the issue tracker」

建一個 GitHub issue（帶 `-R`）。

## 當 skill 說「fetch the relevant ticket」

跑 `gh issue view <number> -R ycpss91255/worktool --comments`。

## Wayfinding 操作

給 `/wayfinder` 用。**map** 是一個 issue，**child** issue 是它底下的 ticket。

- **Map**：一個貼 `wayfinder:map` 標籤的 issue，本文放 Notes／Decisions-so-far／Fog。`gh issue create -R ycpss91255/worktool --title "..." --body-file <檔> --label wayfinder:map --milestone <M>`（不屬於任何 milestone 時拿掉 `--milestone`，改在本文寫一行 `milestone: 無`）。
- **Child ticket**：以 GitHub sub-issue 連到 map 的 issue（用 `gh api` 打 sub-issues endpoint）。sub-issue 沒開的話，把 child 加進 map 本文的 task list，並在 child 本文最上面寫 `Part of #<map>`。標籤：`wayfinder:<type>`（`research`／`prototype`／`grilling`／`task`）。被認領後，ticket 指派給負責的開發者。
- **Blocking**：用 GitHub **原生 issue dependencies**，這是正式、UI 看得到的表示法。加一條邊：`gh api --method POST repos/ycpss91255/worktool/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`，`<blocker-db-id>` 是 blocker 的數字 **database id**（`gh api repos/ycpss91255/worktool/issues/<n> --jq .id`，_不是_ `#number` 也不是 `node_id`）。GitHub 會回報 `issue_dependencies_summary.blocked_by`（只算還開著的 blocker，這就是即時閘門）。dependencies 不可用時，退回在 child 本文最上面寫一行 `Blocked by: #<n>, #<n>`。所有 blocker 都關閉，ticket 才算解除封鎖。
- **Frontier query**：列 map 底下還開著的 child（`gh issue list -R ycpss91255/worktool --state open`，限定在 map 的 sub-issue／task list 範圍），剔除有開著的 blocker（`issue_dependencies_summary.blocked_by > 0`，或 `Blocked by` 那行有還開著的 issue）或已有 assignee 的；依 map 順序第一個勝出。
- **Claim**：`gh issue edit <n> -R ycpss91255/worktool --add-assignee @me`，這是該 session 的第一次寫入。
- **Resolve**：`gh issue comment <n> -R ycpss91255/worktool --body "<answer>"`，接著 `gh issue close <n> -R ycpss91255/worktool`，再把 context 指標（gist + 連結）補到 map 的 Decisions-so-far。
