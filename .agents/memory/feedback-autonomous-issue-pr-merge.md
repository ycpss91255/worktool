---
name: feedback-autonomous-issue-pr-merge
description: "worktool: sub-issue PRs need no per-item approval; TDD + ci-passed green + codex confirms, then merge with a merge commit; the milestone acceptance PR and the release need the maintainer"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
  modified: 2026-09-29T00:00:00.000Z
---

Maintainer authorized (2026-09-15, bounded by the worktool governance of
2026-09-19) autonomous issue and PR handling: open and merge a sub-issue PR
without waiting for per-item approval, PROVIDED it went through TDD (test
first, RED then GREEN), `ci-passed` is green, and codex confirmed it
("可合併"). Merge by hand once all three hold, with a merge commit:
`gh pr merge <n> --repo ycpss91255/worktool --merge` - never squash, never
rebase, never queue a merge for later. Do NOT ask for a per-issue / per-PR
go-ahead.

Still needs the maintainer:
- the milestone acceptance PR (checklist in doc/acceptance.md + Closes the
  parent issue) - a human gate, never merged by an agent;
- the release of the final milestone (M17, version 2.0.0) and any major
  decision (doc/design.md, 治理規則).

**Why:** the maintainer wants throughput on the issue queue; TDD + CI + codex
is the safety net, not a human review of every PR. The milestone gate and the
release are the steps they keep control of.

**How to apply:** default to autonomous open + merge for sub-issue PRs,
through the pr-loop workflow (doc/workflow.md); pause only at the milestone
acceptance PR and the release. Related:
[[feedback-autonomous-test-gap-remediation]], [[feedback-codex-claude-collab]],
[[feedback-per-agent-independent-commit]].
