---
name: feedback-dont-ask-round-approval
description: Never ask the maintainer to approve extra codex rounds or process gates; find the root cause and continue on my own
metadata:
  type: feedback
---

Do not ask the maintainer to approve another codex round, a round-cap
override or similar process gates. Find the root cause of the repeated
finding class, fix the class (normalise / allow-list, equivalence-class
matrix tests, shared single parser), then continue.

**Why:** 2026-09-29, after I asked for `approve codex round 4` on #235/#237:
"不用問我直接做". Earlier: "要找到root cause 在補洞不然永遠補不起來".

**How to apply:** process guards (e.g. #239) require a written root-cause
section, never maintainer approval. Only real product/scope forks go to the
maintainer. Related: [[feedback-decide-when-invariant-settles-it]],
[[feedback-codex-round-stop-rule]].
