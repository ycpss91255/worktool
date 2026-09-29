# Issue tracker：GitHub

本 repo 的 issue 與 spec 都放在 GitHub `ycpss91255/worktool`。所有操作一律用 `gh` CLI。整體設計見 `doc/design.md`、對外介面見 `doc/structure.md`、驗收見 `doc/acceptance.md`。

## 為什麼每個 `gh` 都明寫 `-R`

`gh` 不帶 `-R` 時會靠當下目錄的 remote 推出目標 repo：推得出來也是推測，換個目錄、worktree 或 submodule 就換了答案，有 fork 的 remote 時還會打到 fork。這在 worktool 發生過：在 initialization 的目錄下跑 `gh issue lock <n>`，鎖到的是 initialization 同編號的 issue。所以慣例是**每個指令都明寫 `-R ycpss91255/worktool`**，讓指令自己說出目標，跟從哪裡執行無關。

## 慣例

- **建立 issue**：`gh issue create -R ycpss91255/worktool --title "..." --body-file <檔>`。
- **讀 issue**：`gh issue view <number> -R ycpss91255/worktool --comments`；需要時用 `jq` 過濾留言，並一併抓標籤。
- **列 issue**：`gh issue list -R ycpss91255/worktool --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`，視情況加 `--label`、`--state`、`--milestone`。
- **留言**：`gh issue comment <number> -R ycpss91255/worktool --body-file <檔>`
- **加／移標籤**：`gh issue edit <number> -R ycpss91255/worktool --add-label "..."` ／ `--remove-label "..."`
- **關閉**：`gh issue close <number> -R ycpss91255/worktool --comment "..."`

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

## 當 skill 說「publish to the issue tracker」

建一個 GitHub issue（帶 `-R`）。

## 當 skill 說「fetch the relevant ticket」

跑 `gh issue view <number> -R ycpss91255/worktool --comments`。
