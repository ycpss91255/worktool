---
name: feedback-decide-when-invariant-settles-it
description: When a settled invariant or principle already determines the answer, decide it and record it; do not put it to the maintainer as an A/B question
metadata:
  type: feedback
---

Do not ask the maintainer to choose between options when an already-settled
invariant, principle or rule (mechanism over discipline, one source of truth,
host/box separation, ...) picks the answer. Decide, record the decision and its
basis in the issue, and move on.

**Why:** 2026-09-29, #179: I asked "TMUX_TMPDIR (mechanism) or `tmux -L`
(remember a flag)?" after the invariant "host and box do not interfere" was
settled. The maintainer: "這個不是就是靠機制來做保護嗎? 沒有什麼好詢問我的".

**How to apply:** before asking, check the settled invariants (#200), ADRs and
AGENTS.md rules. Ask only for real product/scope forks or trade-offs no settled
rule decides. Related: [[feedback-codex-round-stop-rule]].
