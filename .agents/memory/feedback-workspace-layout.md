---
name: feedback-workspace-layout
description: "worktool_ws layout - src/ holds only main's latest commit; worktrees in worktool_ws/worktree/<name>, scratch in worktree/.scratch; keep nothing important in /tmp"
metadata:
  node_type: memory
  type: feedback
  originSessionId: b21b8285-cb10-409f-8ab7-1102a23e51e6
  modified: 2026-10-01T00:30:21.122Z
---

`worktool_ws/src` is the main checkout and holds only main's latest commit
(pull --ff-only only). Every worktree lives at `worktool_ws/worktree/<name>`,
agent scratch at `worktool_ws/worktree/.scratch/`, codex job files at
`worktool_ws/codexjobs/`, and notes and archives at `worktool_ws/note/`.
Nothing that matters stays in /tmp.

**Why:** maintainer 2026-10-01, matching vendor-kit's `vendor-kit_ws/worktree/`
layout; /tmp and session scratchpads disappear, and the main checkout must
stay a clean copy of main.

**How to apply:** create worktrees with
`git worktree add ../worktree/<name>` from src; never under `src/.worktree/`
(the repo still hard-codes that until #301 merges, so pass explicit paths).
Before ending a session, move anything worth keeping out of /tmp into
`worktool_ws/note/`. Relates to [[feedback-codex-implements-claude-verifies]].
