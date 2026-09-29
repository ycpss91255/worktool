---
name: feedback-codex-quota-pause
description: "When the maintainer says codex tokens are exhausted: stop calling codex entirely until told otherwise; never impersonate codex; note the gap on each PR; pause/resume work on a time given by the maintainer via a Monitor"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
  modified: 2026-09-19T05:03:44.408Z
---

Maintainer directive (2026-09-19 13:03 CST): "codex token 不夠, 先不要使用, 開一個
monitor 下午5點在繼續動作, 現在都暫停".

**How to apply:**
- Do not call `codex exec` at all until the maintainer says the quota is back.
  PRs still get CI + TDD; on each PR leave a `[claude]` note "codex 暫停中,待配額
  恢復補複驗" instead of a codex verdict. Never write a `[codex]` line yourself.
- "現在都暫停" means stop running agents/workflows immediately (TaskStop), leave
  worktrees/branches in place, and set ONE persistent Monitor that sleeps until the
  named time and emits a resume line; do nothing else until it fires.
- When resuming, first re-check what the stopped agents left (git worktree list,
  branches, open PRs) and continue from there.

**Why:** codex is a metered external service; the maintainer manages its quota and
timing. Impersonating codex would corrupt the collaboration record.

Related: [[feedback-codex-claude-collab]], [[project-worktool-distrobox-redesign]].

**Update 2026-09-19 evening:** maintainer said "現在 token 夠了" -> codex re-enabled; the
PRs merged during the pause (#152-#157) get a catch-up re-verification first.
