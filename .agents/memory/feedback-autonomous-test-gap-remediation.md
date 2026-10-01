---
name: feedback-autonomous-test-gap-remediation
description: "Don't ask permission to fix bugs / close test gaps — drive autonomously via workflows"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

When work reveals a bug or a test-coverage gap, **do not ask the user whether to fix it or how to scope it** — just fix it and close the gap. Drive it autonomously, using a Workflow with parallel agents where the work decomposes (the user's standing preference: "能用 workflow 的就用", and "這種事情不用問").

**Why:** the user treats "currently failing / untested" as an obvious, standing mandate — "目前來看就是沒有通過測試,需要持續修復" (2026-06-19). Asking for permission on each fix/test-gap is friction they explicitly rejected.

**How to apply:** file the tracking issue, deliver the fix + regression test through the pr-loop workflow (own worktree under `../worktree/`, TDD, the six `just test <tier>` gates in Docker, run in the foreground per [[feedback-subagent-no-background-verify]]), then merge per [[feedback-autonomous-issue-pr-merge]] (CI green + codex confirmed, merge commit). Only stop to ask when there's a genuine *product/scope* fork (e.g. which feature to build, or the release — it is outward/irreversible and still needs a yes).

Concrete example that set this (in init_ubuntu, worktool's predecessor): a real-install bug slipped through every test because no test exercised the real non-dry-run path. The fix + a regression test + a real-engine harness were expected as autonomous follow-through, not a question. worktool's counterpart is the real-engine system tier (`just test system-real`).
