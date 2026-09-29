---
name: feedback-per-agent-independent-commit
description: "worktool: each sub-agent's work is its own independent commit; do not mix multiple agents into one commit; merge milestone PRs preserving commits (not squash)"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
  modified: 2026-09-15T15:51:46.668Z
---

Maintainer directive (2026-09-15, worktool redesign, applies going forward):
each agent uses its OWN independent commit; do not mix multiple agents' work
into a single commit.

**How to apply to fan-out milestones (M3+):** when a milestone's sub-issues are
fanned out to several parallel sub-agents, each agent works in its OWN
worktree/branch and produces ONE commit for its sub-issue. Collect each agent's
single commit onto the milestone branch as a DISTINCT commit (e.g. cherry-pick
each), then open one milestone PR and MERGE PRESERVING COMMITS (gh pr merge
--merge or --rebase, NOT --squash) so every agent's commit stays in history and
maps to its sub-issue. Never have two agents commit to the same branch/worktree
concurrently (shared /source races -> spurious failures; see
[[project-workflow-concurrency-ram-cap]]).

M2 (PR #20, pending human gate) already has distinct commits (initial + two fix
rounds); merge it preserving them, not squashed.

Contrast with init_ubuntu, where milestone/issue PRs were squash-merged. worktool
uses non-squash merges to keep per-agent commits. Related:
[[feedback-codex-claude-collab]], [[feedback-autonomous-issue-pr-merge]].
