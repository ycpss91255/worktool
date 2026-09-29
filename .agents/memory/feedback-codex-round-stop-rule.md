---
name: feedback-codex-round-stop-rule
description: Stop codex re-verification rounds once findings are no longer functional bugs; never ask the maintainer whether a round is worth it
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
  modified: 2026-09-28T08:12:38.877Z
---

On worktool PR #174 I ran five codex rounds and kept forwarding every finding to the
implementation agent, including pure wording adjustments and a guard against 64-bit
overflow that cannot occur until 2262. Then I asked the maintainer whether the work was
still meaningful. Both were wrong.

**Why:** the maintainer wants working software, not unbounded defensive hardening. Rounds
1-2 caught real defects (both negative tests were false-green, `run cat` clobbering
`$status`, a shell injection through ghostty's `command`, a uutils `date %3N` bug, a flaky
5-second threshold). Rounds 3-5 degenerated into "the doc claims slightly more than the
code proves". Forwarding those burns hours and ships nothing. Asking the maintainer to
adjudicate the stop rule wastes their time on a call I am supposed to make.

**How to apply:** open a new codex round only when the finding is a false-green, a
functional bug, or a flaky test. Record wording/claim-strength findings as doc debt in a
follow-up issue and merge. Decide this myself and say what I decided - do not present it
as a question. See [[feedback-codex-claude-collab]] for the collaboration gate itself,
which still stands; this only bounds how many rounds it gets.
