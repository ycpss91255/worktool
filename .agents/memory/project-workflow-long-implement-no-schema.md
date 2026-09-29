---
name: project-workflow-long-implement-no-schema
description: "Workflow authoring: do NOT put a StructuredOutput schema on a long implement stage; it fails to emit and errors the run"
metadata: 
  node_type: memory
  type: project
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

In the implement->review->integrate Workflow pattern, a LONG implement agent
(many tool calls / big token spend) frequently finishes its work but does NOT
call StructuredOutput at the end, so `agent(..., {schema})` throws
"subagent completed without calling StructuredOutput (after 2 in-conversation
nudges)" and the whole workflow errors -- AFTER the work is done (seen on
fish-lint wf_94eac787 ~112k tok, and LPT-sharding wf_d45041d7 ~185k tok). Adding
"you MUST call StructuredOutput" to the prompt did NOT prevent it.

**Fix (apply to all long implement workstreams):**
- Do NOT attach a schema to the implement agent. Give it a HARDCODED branch name,
  have it work + `git commit` on that branch (so the work is durable even if the
  final message is lost), and return free text (the workflow ignores it).
- The review / fix / integrate stages take the hardcoded BRANCH name and locate
  the worktree themselves with `git worktree list | grep <branch>` (or read the
  worktree path from that), instead of depending on the implement agent to return
  a worktreePath via schema. Keep schemas only on the SHORT stages (review verdict,
  integrate result) where StructuredOutput reliably fires.
- If it still errors post-work, SALVAGE: a read-only diagnostic agent finds the
  orphaned worktree by branch, assesses completeness, then a commit-then-gate
  workflow finishes it (pattern used for fish-lint -> PR #296).

**Why:** the schema requirement at the end of a long agent session is the fragile
point; committing early + locating-by-branch removes the dependency.

**Bigger root cause (added 2026-07-05):** the failure hits ANY long-running stage,
not just implement -- the LPT salvage's review/integrate stages failed the same
way after 156 min. The reason those stages run so long is they RE-RUN the local
single-pass `just -f justfile.ci coverage` (kcov over ~120 specs = 30-40 min on
this box). That is (a) slow, (b) the CPU-oversubscription culprit, AND (c)
REDUNDANT -- the authoritative AC-17 coverage check is the PR's CI sharded
coverage-merge, not the local single-pass. Fix: **review/fix/integrate stages
should run only `test-unit` + `test-integration` locally (fast) and rely on the
PR's CI for coverage.** The implement stage may run coverage once. This keeps
agent sessions short (reliable StructuredOutput) AND cuts CPU load. Note: a
failed-at-StructuredOutput integrate stage often ALREADY pushed + opened the PR +
armed auto-merge before dying -- check `gh pr list --head <branch>` and just
dual-watch the PR rather than re-running (LPT -> PR #298 this way).

**Sub-agents must run gates as BLOCKING FOREGROUND bash (added 2026-07-07):** a
worktree implement agent got STUCK by "arming a Monitor + background task to wait
for the unit gate, then stopping to wait for that event" -- but a sub-agent CANNOT
wait for a background event across turns, so it returned mid-work without ever
committing/pushing/opening the PR (issue #314 glow module, wf_6bd046d0 pilot: came
back status=no-pr). Fix: every implement/fix/finalize prompt MUST say explicitly
"run each gate as a BLOCKING foreground command and wait for it to exit; do NOT use
the Monitor tool, run_in_background, or ScheduleWakeup; complete ALL steps
synchronously in your own turn." The Monitor/dual-watch pattern is for the MAIN
loop only, never inside a sub-agent. Also add a STEP-3b "if already resolved on
main, close the issue instead of opening a PR" branch (issue #273 was already fixed
by #291 -> the agent should `gh issue close`, not implement).

**Sub-agents must NOT arm auto-merge or post PR comments; the MAIN LOOP does
(added 2026-07-08):** in the P2a batch (wf_af4efd27) the finalize sub-agents' `gh
pr merge --auto` was BLOCKED by the safety classifier on every PR ("Merge Without
Review / External System Writes / agent-inferred out-of-scope target") because a
fresh sub-agent arming auto-merge on a PR it did not create this session trips the
classifier -- it only "knew" the originally-discussed P1 issue numbers as
authorized. Review sub-agents posting `gh pr comment`/`gh pr review --approve` also
tripped "Auto-Mode Bypass / Self-Approval" (and got permission-denied, then tunneled
via --body-file = another flag). FIX (now baked into the p1-queue workflow): (a)
review stage returns the verdict as an INTERNAL handback only -- no PR comment, no
gh pr review; (b) REMOVE the finalize stage entirely; the workflow returns approved
PR numbers and the MAIN LOOP arms auto-merge via
`.claude/script/auto-merge-on-green.sh` Monitors (main loop has the /goal
authorization, so it is not blocked). The human-facing fix-proof still lives in the
PR BODY written by the implement stage (satisfies "provide proof in the PR").

**Parallel PRs always conflict on CHANGELOG.md / doc/module/INDEX.md / TODO.md
(added 2026-07-08):** every change appends to these shared files (the
changelog-drift hook + INDEX auto-gen require it), so N parallel PRs go DIRTY the
moment the first merges. auto-merge-on-green.sh handles BEHIND (update-branch) but
NOT DIRTY. FIX: a `reconcile.workflow.js` (scratchpad) whose sole stage per PR does
`git merge origin/main` + union-resolve the shared files (keep BOTH main's entries
AND the branch's) + re-run the 3 gates blocking-foreground + push; then the main
loop arms auto-merge. INDEX.md's "N modules" header count line is the usual real
conflict; the table body union-merges cleanly.

**N concurrent CHANGELOG-touching PRs = merge thrash; land them SERIALLY and
MECHANICALLY (added 2026-07-10):** landing 11 P2/P3 PRs at once was a nightmare -
every PR appends to CHANGELOG.md [Unreleased] (+ INDEX.md/TODO.md), so each merge
re-DIRTYs the siblings; arming auto-merge on all of them + reconciling in parallel
THRASHES (reconcile push -> GitHub recompute -> a sibling auto-merges -> everyone
DIRTY again). Two fixes: (1) the conflicts are almost always CHANGELOG/INDEX/TODO
APPEND-unions that `git merge origin/main` resolves AUTOMATICALLY via the ort
strategy - no human judgment, so you do NOT need an agent+Docker-gate reconcile;
a MAIN-LOOP bash script in a dedicated detached worktree can `git merge origin/main`
+ push (CI on the PR is the real gate; the local gate re-run was redundant).
(2) SERIALIZE: disable auto-merge on ALL of them first (`gh pr merge --disable-auto`),
then land ONE at a time - merge main into branch, push, arm, WAIT for it to MERGE,
only then move to the next - so main advances one PR at a time and no sibling
re-dirties. See scratchpad/serial-land.sh. ALSO: prefer FEWER, LARGER PRs for
follow-on work (all mechanical ADR fixes in one PR, all fork changes in one PR)
to minimize CHANGELOG contention in the first place. (Reconcile AGENTS still keep
stalling on the Monitor/background antipattern despite explicit instructions - a
main-loop mechanical merge sidesteps that entirely.)
AUTO-GENERATED files must be REGENERATED after a merge, NOT union-merged: a
union-merge of `doc/module/INDEX.md` produced a stale file that failed the meta-test
`not ok "committed doc/module/INDEX.md is up to date"` (a stale branch cut 45h ago
kept old module rows; union with new main != a clean regeneration). Fix: after
`git merge origin/main`, run `( cd <wt> && ./script/gen-module-index.sh >
doc/module/INDEX.md )` and commit if changed (the generator is a pure host-side
text tool, no Docker/install needed). serial-land.sh does this. Any reconcile of
these branches must regenerate INDEX.md, not trust the ort union.

**Workflows accumulate worktrees and never auto-clean (added 2026-07-08):** after a
few batches `git worktree list` hit 54 entries, and stale worktrees keep the
`auto/issue-*` branches checked out so a reconcile agent's `git switch <branch>`
fails ("already checked out"). FIX between batches: loop `git worktree list
--porcelain` and `git worktree remove --force <path>` every non-main worktree, then
`git worktree prune`. ~1/3 fail to delete the DIRECTORY (root-owned Docker artifacts
inside, e.g. .tmp/sync-e2e ssh keys) but prune still frees the git registration +
branch lock, which is what unblocks reconcile; the leftover dirs need a later `sudo
rm -rf .worktree/wf_* .worktree/agent-*`.

**Adversarial verifiers still pass false positives; main loop MUST spot-check
CONFIRMED findings against current code (added 2026-07-15):** a module-review
workflow (8 review groups -> per-finding adversarial REFUTE verifier -> synth)
returned 2 CONFIRMED MEDIUMs. One was a FALSE POSITIVE that the refute-verifier
still marked CONFIRMED with a verbatim citation: it claimed `module_default_doctor`
runs only `is_installed` (hollow doctor), citing lib/module_helper.sh:174 -- but
174 is inside `module_default_verify` (starts 172); the real `module_default_doctor`
(starts 189) DOES run is_installed + TEST_VERIFY_CMD (fixed long ago by #369). Both
reviewer and verifier conflated the two ADJACENT functions and cited a line in the
wrong one. Signal it was wrong: it CONTRADICTED a known-fixed memory. Lesson: before
acting on any CONFIRMED review finding, the MAIN LOOP reads the actual current code
(especially when the finding contradicts a memory / known-fixed state, or cites a
line near a function boundary) -- do not auto-dispatch fixes straight from the
verified verdict. The OTHER finding (cowsay doctor/verify probed bare `command -v`
but the apt binary lives at /usr/games/cowsay, off non-login PATH -> false health
failure) WAS real; fixed via one TDD worktree agent (probe now
`command -v cowsay || [ -x ${COWSAY_GAMES_BIN:-/usr/games/cowsay}]`, spec stops
faking it onto PATH) -> PR #391 -> re-review PASS. So the review round netted 1 real
fix out of 2 confirmed, the false one caught only by the main-loop code re-read.

**How to apply:** author future sh workstreams with no-schema implement +
branch-located later stages + test-unit/test-integration-only gates + explicit
blocking-foreground-gate instruction (no Monitor inside sub-agents) + review returns
internal verdict only + main-loop arms auto-merge + a reconcile pass for DIRTY +
periodic worktree cleanup. Related: [[project-sh-completeness-program]],
[[project-workflow-concurrency-ram-cap]].
