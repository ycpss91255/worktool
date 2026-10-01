---
name: feedback-main-session-coordinates-only
description: "Main conversation only decides and coordinates; every edit (even one line), research and verification goes through a workflow or sub-agent; ask the maintainer only after a codex discussion fails to agree"
metadata:
  node_type: memory
  type: feedback
  originSessionId: b21b8285-cb10-409f-8ab7-1102a23e51e6
  modified: 2026-10-01T01:39:55.260Z
---

The main conversation only decides and coordinates. Every change to a repo
file goes through a workflow, even one or two lines (docs, scripts, tests,
workflows, hooks, CI, .gitignore); the main conversation does only read-only
checks (grep, lint, tests), commit / push, and issue comments. External
research goes through a workflow (agy finds, codex checks each source, Claude
spot-checks and writes the synthesis; unresolved points are listed as
分歧, not decided). Before asking the maintainer, discuss with codex (each
answers independently, at most 3 rounds); ask only what stays disputed, one
question at a time; anything an invariant, a settled issue or a repo
precedent decides, decide and report. Issue titles and bodies are not edited
after creation; updates are comments starting with [claude] / [codex] / [agy]
([codex] / [agy] hold only the verbatim text). Every claim to the maintainer
carries evidence (issue link, file:line, URL) or is marked 推論. /tmp and the
scratchpad hold only one-off scripts, deleted after use; process artefacts
(backups, review logs, drafts) stay under the workspace and out of git.

**Why:** maintainer rule, relayed 2026-10-01 from the vendor_kit session
("修改的部分使用workflow 做處理不要你自己做", "這個事情應該使用 workflow 做處理才對",
"tmp 裡面只放一次性腳本, 用完就要做移除"). vendor_kit implements it with
doc-edit.js (light / full modes), research.js and discuss.js
(ycpss91255-research/vendor_kit PRs #59, #63).

**How to apply:** in worktool use pr-loop for code changes and
research-verify for research. worktool has no discuss workflow and no light
mode yet; until they exist, small edits still go through pr-loop and
codex discussions use a codex job. Relates to
[[feedback-decide-when-invariant-settles-it]],
[[feedback-codex-implements-claude-verifies]], [[feedback-workspace-layout]].
