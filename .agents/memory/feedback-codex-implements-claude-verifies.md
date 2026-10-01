---
name: feedback-codex-implements-claude-verifies
description: "since 2026-09-30 codex does the implementation (tests, code, local gates, commit, push, PR); Claude only does the final verification and the merge"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 586d4a0d-f187-4d46-bda8-a08d6f3a30b9
  modified: 2026-10-01T08:45:16.714Z
---

Roles are swapped: codex implements every sub-issue; Claude only verifies and merges. The maintainer: "背景工作全部停止, 改用 codex 做, 你只做最後驗證" then "兩者工作調換".

- codex runs with `--dangerously-bypass-approvals-and-sandbox` (maintainer chose it: the host denies bwrap user namespaces, so the codex sandbox cannot run any command), `-C` the PR's own worktree (`worktool_ws/worktree/<name>`, #301), confined by the prompt to that worktree. Normal delivery is the `pr-loop` workflow (implementer=codex, #283); `worktool_ws/codexjobs/run.sh` remains only for follow-up jobs on an existing PR.
- Shared rules for every job live in the workflow guardrails (worktree-only, TDD vertical slices per `.agents/skills/tdd/SKILL.md`, local tests only the touched specs plus lint, CI runs every tier (ADR 0014), noreply identity, no attribution lines, no emoji, zh-TW PR text starting with `[codex]`, never merge / rewrite pushed commits / touch main).
- At most 10 codex jobs at a time (maintainer, 2026-10-01; raised from 2 once local runs became changed-specs-only, #298-#307; `milestone-fanout` batch size follows in #322). The separate cap of 2 running test containers (CPU gate, #279/#288) still applies and may delay new launches. Each job is its own background task so it can be verified as soon as it finishes.
- Claude's verification: read the diff and commits (vertical slices, behaviour tests, attribution-free, noreply, no stray files), check CI green, then merge with a merge commit; otherwise send the findings back to codex as a follow-up job. Codex DOES load repo hooks: `.codex/hooks.json`, same stdin as Claude (`tool_name: "Bash"`, `tool_input.command`), exit 2 blocks; file edits arrive as `tool_name: "apply_patch"` with the patch text (measured 2026-09-30). #282 registers every guardrail hook for codex; run codex with `--dangerously-bypass-hook-trust`. Until #282 merges, this review is the only enforcement.

**Why:** Claude-run implementation was slow and drifted from the rules; the maintainer moved implementation to codex and kept Claude as the gate.

**How to apply:** never implement yourself; write the job prompt, start codex, verify, merge. Related: [[feedback-guardrails-before-milestone]], [[feedback-codex-claude-collab]].
