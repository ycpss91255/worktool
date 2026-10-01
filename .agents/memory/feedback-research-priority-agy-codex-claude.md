---
name: feedback-research-priority-agy-codex-claude
description: "Research/lookup: ambiguity -> research first; priority agy (gemini) -> codex -> claude sub-agent as last resort; requests to gemini must be explicit"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
  modified: 2026-10-01T09:40:05.746Z
---

Maintainer directives (2026-09-16):
- During implementation, anything ambiguous or unclear -> do research FIRST, never guess.
- Research tool PRIORITY, fall through in order only when the earlier one lacks
  tokens/quota, times out, or returns nothing:
  1. agy (= gemini / Google Antigravity; the maintainer calls it "agy 也就是 gemini")
  2. codex
  3. a claude sub-agent (LAST resort)
- Requests to gemini must be EXPLICIT: a concrete question, and ask for cited sources.
- codex, when it needs a lookup, should also route it to gemini (agy).

**Model (maintainer, 2026-10-01): agy always uses the NEWEST model** ("一律使用最新的
模型, 現在是 3.8"). Never hard-code a version: resolve it from `agy models` each run
(highest-version Gemini flash `high` variant; today `gemini-3.8-flash-high`) and pass
`--model <resolved>`; if resolution fails, fail closed. Every workflow that calls agy
uses the shared resolver (#325).

**How to call agy headless:** `agy --model <newest, from agy models> --sandbox
--dangerously-skip-permissions -p "<explicit question>" --print-timeout 5m` (wrap in
`timeout`). Plain `-p` without skip-permissions
gets auto-denied on tool use (headless cannot prompt) and returns nothing; --sandbox
keeps its terminal restricted. It is SLOW (a 3m print-timeout returned partial/empty);
allow ~5m. The plain `gemini` CLI is DEAD for this account (UNSUPPORTED_CLIENT: migrate
to Antigravity) -- do not use it. codex: `... | codex exec --skip-git-repo-check "<prompt>"`
(feed material on stdin, no </dev/null).

**Before asking the maintainer for a decision (added 2026-09-16):** research industry
convention FIRST (agy -> codex -> claude) and present a RECOMMENDATION with sources;
never hand the maintainer bare options un-researched. Track the decision on GitHub:
tag the issue `needs-decision` (worktool label) and, if it is a new topic, open a new
issue / milestone sub-issue to carry the discussion + research. (Example: the M2
real-engine system-test approach -- agy research concluded docker-in-docker with
--privileged is the practical choice; DooD is fatally broken for distrobox due to
path mismatch; rootless podman-in-docker is fragile.) Locking visibility: use native
`blocked by` dependencies (visible in list/sidebar), not a `locked` label.

**Why:** the maintainer wants cheaper/dedicated tools to do lookups and claude to spend
its context on orchestration; and wants no guessing on unclear implementation details.

Related: [[feedback-codex-claude-collab]], [[project-worktool-distrobox-redesign]].
