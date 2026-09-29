---
name: feedback-codex-claude-collab
description: "worktool: before closing an issue or merging a PR, claude discusses with codex; record the Chinese discussion in the issue/PR tagged [claude]/[codex]; only proceed if codex confirms"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
  modified: 2026-09-15T16:50:27.451Z
---

Maintainer wants a codex+claude collaboration gate (asked 2026-09-15, for the
worktool redesign; applies going forward). codex CLI is installed at
~/.local/bin/codex (codex-cli 0.153.4, model gpt-6-astra, read-only sandbox).

**How to invoke codex non-interactively:**
`<material> | codex exec --skip-git-repo-check "<prompt>"` -- feed the diff/context
via STDIN (a pipe). Do NOT also add `</dev/null`: that redirect overrides the pipe
and codex receives empty stdin (learned the hard way -- codex replied "no diff
provided"). Wrap in `timeout` (long-job hook). codex cannot read the repo files
itself (sandbox), so give it everything it needs on stdin.

**Protocol:** before CLOSING an issue or MERGING a PR, claude runs a codex review
(feed the diff / the work), confirms there are no problems, and records the
discussion as a comment on that issue/PR. All in zh-TW. Every message is tagged
`[claude]` or `[codex]`. Only close/merge after codex confirms ("沒有問題,可合併"
or equivalent). If codex flags problems, fix them, then re-review with codex.
Creation of planning issues does NOT trigger this; only the close/merge gate does.
This composes WITH the milestone human gate + CI green (all three must hold).

**Why:** the maintainer wants an independent second AI reviewer before anything
lands. Proven valuable immediately: codex's first review (M2 PR #20) found 4 real
P2 robustness issues + a missing negative test that CI + claude had passed.

**Evidence + re-verification requirements (added 2026-09-15):**
- Attach BOTH the local test results (the Docker gate output: lint/unit/integration
  with counts) AND the CI results (gh pr checks, with run links) to the issue/PR as
  an evidence comment. Both, not just one.
- codex must do an EXPLICIT re-verification after fixes, and its result must be
  posted to the issue/PR. The re-verification prompt MUST include the FULL context:
  the complete list of the original findings PLUS the current full diff, so codex
  can confirm EACH finding item-by-item (not a vague "looks fine"). A codex reply
  that says it lacks the full findings list = an INVALID re-verification; redo it
  with full context.
- claude must DOUBLE-CHECK codex's re-verification process is correct: did codex
  receive the full findings + diff, did it address every item, is its verdict
  grounded. codex reviews STATICALLY (its sandbox cannot execute tests), so the
  actual test-execution evidence always comes from claude's local Docker gates +
  GitHub CI; codex's role is static code review. State this split honestly on the PR.

**Four-test-level check (added 2026-09-16):** every codex milestone review MUST
explicitly verify that all FOUR test levels are genuinely present -- unit /
integration / system / acceptance -- not merely a `skip` placeholder. Any missing
level = that milestone is DEFECTIVE and must NOT pass the gate; claude and codex
discuss the fix, then implement it. (Triggered on M2, whose system test was a skip
placeholder because real distrobox assemble needs docker-in-docker; candidate fix:
real distrobox binary in the test image + a fake container-manager shim via
DBX_CONTAINER_MANAGER so distrobox truly parses the INI; acceptance = the 3g
self-check wired as an automated test + the human checklist.)

Related: [[feedback-autonomous-issue-pr-merge]] (worktool milestones still keep the
human gate per its own governance), [[project-template-first-program]].
