---
name: feedback-guardrails-before-milestone
description: "process/guardrail work (agent hooks, CI checks, workflow template fixes, governance docs) goes before milestone feature work, one PR at a time when they share files"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 586d4a0d-f187-4d46-bda8-a08d6f3a30b9
  modified: 2026-09-30T06:54:27.929Z
---

Order of work: non-milestone process work first (agent guardrail hooks, CI checks, workflow template fixes, governance/ADR docs), milestone feature PRs after. Within the guardrail work, the item that protects the most later work goes first (e.g. CPU gate, then attribution block, then tdd enforcement). Hook PRs that all touch `.claude/settings.json`, `test/unit/agent_config_spec.bats` and the `doc/structure.md` hook list run strictly one at a time: implement, codex, CI, merge, then the next.

**Why:** 2026-09-30 I paused the non-M3 work to push M3; the maintainer corrected: "不對, 非 M3 的要先做". Guardrails landed first make every later PR follow the new rules instead of being retrofitted.

Parallelism: group the queue into lanes by the files they touch (hooks/settings.json; workflow templates; ADR docs). Within a lane, one PR at a time only when the overlap is real logic; hook PRs whose only overlap is one registration line in `.claude/settings.json` / `agent_config_spec.bats` / the `doc/structure.md` hook list run concurrently and resolve by keeping both lines (maintainer approved 2026-09-30: "A ok"). After merging origin/main with no logic change, skip the local gates and let CI verify; different lanes run in parallel whenever the host has headroom (resource governor caps concurrent test containers). The maintainer: "可以並行處理且系統資源還足夠就同步執行".

**How to apply:** when choosing what to run next, finish the guardrail queue before resuming milestone PRs; do not interleave hook PRs that edit the same registration files. Related: [[feedback-do-repo-admin-myself]], [[project-worktool-distrobox-redesign]].
