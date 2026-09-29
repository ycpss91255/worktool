---
name: feedback-autonomous-issue-pr-merge
description: "issue/PR need no per-item approval; follow /tdd + wait for CI green, then merge directly; ONLY releases need explicit user consent"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
  modified: 2026-09-15T11:51:58.820Z
---

Maintainer authorized (2026-09-15) autonomous issue and PR handling: create and
merge without waiting for per-item approval, PROVIDED the change follows /tdd
(tests-first where applicable) and the PR's CI passes. Arm auto-merge so a PR
lands only on green. Do NOT ask for per-issue / per-PR go-ahead. For clear/ready
issues, dispatch sub-agents (worktree + TDD) and serial-land on green. The ONE
exception that still needs explicit consent: cutting a RELEASE (git tag via
release-tag.sh) -- never auto-release.

**Why:** the maintainer wants throughput on the issue queue; the /tdd + CI-green
gate is the safety net, not a human review gate. A release is the one
irreversible outward step they keep control of.

**How to apply:** default to autonomous create+merge for issues/PRs; only pause
for releases. Note: the repo's `enforce_gh_review_approval.sh` hook still expects
a per-session approval phrase before `gh pr/issue create`; if that friction
recurs, offer to align the hook with this policy rather than asking the maintainer
to repeat approval. Related: [[feedback-autonomous-test-gap-remediation]],
[[project-release-tag-ceremony]].
