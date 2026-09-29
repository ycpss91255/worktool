# Domain docs

工程類 skill 在探索這個 repo 時，應該怎麼使用領域文件。

## 動手之前先讀這些

- **`doc/design.md`**：願景、治理規則、已定共識、milestone 計畫。
- **`doc/structure.md`**：目錄結構與對外介面（`just` 指令表、錯誤來源與結束碼）。
- **`doc/enter.md`**、**`doc/manifest.md`**：終端自動進盒與盒子清單兩塊的行為與格式。
- **`doc/acceptance.md`**：各 milestone 的驗收項目。
- **`CONTEXT.md`**（repo 根目錄）：名詞與縮寫，本 repo 的專有名詞表。
- **`doc/adr/`**：讀跟你要動的範圍有關的 ADR。

上面任一檔不存在時，**安靜略過**：不要指出它缺席，也不要建議先建它。`/domain-modeling` skill（經 `/grill-with-docs` 與 `/improve-codebase-architecture` 觸發）會在名詞或決議真的定下來時才建立。

## 檔案結構

單一語境：

```text
/
├── AGENTS.md          （CLAUDE.md 是指向它的 symlink）
├── CONTEXT.md
└── doc/
    ├── adr/
    ├── agent/
    ├── diagram/
    ├── design.md
    ├── structure.md
    ├── enter.md
    ├── manifest.md
    └── acceptance.md
```

沒有 `CONTEXT-MAP.md`，整個 repo 只有一個語境。目錄名一律單數（見 `doc/structure.md`），skill 範本寫 `docs/adr/`、`docs/agents/` 時對應到這裡的 `doc/adr/`、`doc/agent/`。

## 用名詞表的詞

輸出裡提到領域概念時（issue 標題、重構提案、假設、測試名），用 `CONTEXT.md` 定義的那個詞，不要滑到名詞表明列「避免的說法」裡的同義詞。

需要的概念不在名詞表裡，那是一個訊號：要嘛你在發明本 repo 沒在用的語言（重新考慮），要嘛真的有缺口（記下來給 `/domain-modeling`）。

## 標出跟 ADR 或已定共識衝突的地方

輸出跟既有 ADR 或 `doc/design.md` 的已定共識矛盾時，明講出來，不要默默蓋過：

> _跟已定共識第 3 條（tmux 在盒內）矛盾，但值得重開，因為……_
