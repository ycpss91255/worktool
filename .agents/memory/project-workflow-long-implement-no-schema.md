---
name: project-workflow-long-implement-no-schema
description: "Workflow authoring: do NOT put a StructuredOutput schema on a long implement stage; it fails to emit and errors the run"
metadata: 
  node_type: memory
  type: project
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

Lessons from running implement -> review -> integrate Workflows (first seen
in init_ubuntu, worktool's predecessor; they shaped worktool's pr-loop and
milestone-fanout templates, doc/workflow.md).

**Long stages fail to emit StructuredOutput.** A LONG implement agent (many
tool calls / big token spend) often finishes its work but never calls
StructuredOutput, so `agent(..., {schema})` throws "subagent completed
without calling StructuredOutput" and the whole workflow errors -- AFTER the
work is done. Telling it "you MUST call StructuredOutput" did not help.
- Do NOT attach a schema to the implement agent. Give it a HARDCODED branch
  name, have it `git commit` on that branch (durable even if the final
  message is lost), and ignore its free-text return.
- Later stages take the branch name and locate the worktree themselves
  (`git worktree list | grep <branch>`); keep schemas on SHORT stages only
  (locate the PR, the codex verdict).
- If a run still errors after the work, salvage: find the worktree by
  branch, check `gh pr list --head <branch> --repo ycpss91255/worktool`, and
  continue from there instead of re-running.

**Sub-agents run gates BLOCKING in the foreground.** A sub-agent cannot wait
for a background event across turns: one that armed a Monitor / background
task for its gate returned mid-work and never pushed. Every implement / fix
prompt says: run each `just test <tier>` as a blocking foreground command;
no Monitor, no run_in_background. Monitor is for the MAIN loop only (see
[[feedback-subagent-no-background-verify]]). If the issue is already fixed on
main, close it instead of opening a PR.

**Sub-agents never merge.** The workflow only pushes and reports; the MAIN
loop merges, one PR at a time, after CI is green and codex confirmed
([[feedback-autonomous-issue-pr-merge]]). A fresh sub-agent merging a PR it
did not create also trips the safety classifier.

**Verify CONFIRMED review findings against current code.** Adversarial
verifiers still pass false positives (one cited a line inside the ADJACENT
function and was marked CONFIRMED). Before dispatching a fix, the main loop
re-reads the cited code, especially when a finding contradicts a known-fixed
state or sits near a function boundary.

**Workflows accumulate worktrees.** Between batches, `git worktree remove
--force` every finished `.worktree/<name>` and `git worktree prune`; stale
worktrees keep branches checked out and block a later `git switch`.

Related: [[project-workflow-concurrency-ram-cap]].
