---
name: feedback-guardrails-before-milestone
description: "process/guardrail work (agent hooks, CI checks, workflow template fixes, governance docs) goes before milestone feature work; lanes by shared files run in parallel, serial only on real logic overlap"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 586d4a0d-f187-4d46-bda8-a08d6f3a30b9
  modified: 2026-09-30T08:13:02.192Z
---

Order of work: non-milestone process work first (agent guardrail hooks, CI checks, workflow template fixes, governance/ADR docs), milestone feature PRs after. Inside the guardrail work, the item that protects the most later work goes first (e.g. CPU gate, then attribution block, then tdd enforcement).

Parallelism rule (one rule, no exceptions elsewhere in this file):
- Hard cap: at most 2 test runs (running test containers) at once on this host; the maintainer: "一次最多跑兩個就好, 不要多跑電腦吃不消" (2026-09-30). Parallel lanes still exist, but the resource governor lets only 2 test containers run; everything else waits.
- Group the queue into lanes by the files the PRs touch (hooks; workflow templates; ADR docs). Different lanes run in parallel whenever the host has headroom (the CPU gate hook and the resource governor cap concurrent test containers).
- Inside a lane, PRs run in parallel too when their only overlap is a registration line (`.claude/settings.json`, `test/unit/agent_config_spec.bats`, the `doc/structure.md` hook list): on a merge of origin/main keep both lines.
- Inside a lane, PRs run one at a time only when they change the same logic (e.g. #271 reuses the detector #270 creates; #226 rewrites every existing hook header).
- After merging origin/main with no logic change, skip the local gates and let CI verify.

**Why:** 2026-09-30 I paused the non-M3 work to push M3; the maintainer corrected: "不對, 非 M3 的要先做". Then: "可以並行處理且系統資源還足夠就同步執行", and approved running the hook PRs of one lane concurrently ("A ok") after seeing that the lane-serial queue cost 7 hours for conflicts that were one registration line each.

**How to apply:** when choosing what to run next, finish the guardrail queue before resuming milestone PRs; start every PR whose overlap is only registration lines at once; hold back only the ones with real logic overlap. Related: [[feedback-do-repo-admin-myself]], [[project-worktool-distrobox-redesign]].
