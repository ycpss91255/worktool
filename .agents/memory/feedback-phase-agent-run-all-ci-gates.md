---
name: feedback-phase-agent-run-all-ci-gates
description: Implementation sub-agents must run all six Docker gates (just test lint / unit / integration / system / acceptance / system-real) before reporting green — not a subset
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

When delegating an implementation to a worktree sub-agent, the agent's
"green" report MUST come from running every gate CI runs, in Docker, through
the user interface: `just test lint`, `just test unit`,
`just test integration`, `just test system`, `just test acceptance` and
`just test system-real` (bare `just test` runs all six in that order). A
subset is not enough; a docs-only change may narrow to lint + unit only when
the task says so (doc/workflow.md, `gates`).

**Why:** in init_ubuntu (worktool's predecessor) an agent ran only two of
its gates and reported green, but its change broke a smoke test that only
the skipped integration gate exercised; CI caught it, costing a red PR and a
fix round-trip. The tiers exercise different surfaces; passing one says
nothing about another.

**How to apply:** put "run all six `just test <tier>` gates, blocking in the
foreground, all green, before reporting" explicitly in every implementation
prompt. On a red CI job, check `gh pr checks <n> --repo ycpss91255/worktool`
first to see WHICH job (and which runner leg) failed. Relates to
[[feedback-autonomous-test-gap-remediation]] and [[project-ci-lint-covers-bats]].
