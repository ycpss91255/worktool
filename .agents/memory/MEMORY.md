# Memory index (worktool)

Every entry is a real file in this repo (.agents/memory/, reached as
.claude/memory/); nothing is linked from another repo or from user level.

## worktool
- [Codex+claude collab gate](feedback-codex-claude-collab.md) — worktool: before closing issue / merging PR, claude discusses with codex; record zh-TW discussion tagged [claude]/[codex]; only proceed if codex confirms
- [Codex round stop rule](feedback-codex-round-stop-rule.md) — open a new codex round only for false-green / functional bug / flaky; wording findings become doc debt; decide it myself, never ask
- [Decide when an invariant settles it](feedback-decide-when-invariant-settles-it.md) — a settled invariant/principle already picks the answer: decide and record it, do not ask the maintainer A or B
- [No approval asks for rounds](feedback-dont-ask-round-approval.md) — never ask the maintainer to approve extra codex rounds or process gates; find the root cause, fix the class, continue
- [Do repo admin myself, reply zh-TW](feedback-do-repo-admin-myself.md) — authorised repo admin ops (rename, protection, approved rewrite) I finish myself; only browser OAuth goes to maintainer; always reply zh-TW
- [Guardrails before milestone work](feedback-guardrails-before-milestone.md) — non-milestone process work (hooks, CI checks, templates, ADRs) goes first; lanes by shared files in parallel, serial only on real logic overlap
- [Codex implements, Claude verifies](feedback-codex-implements-claude-verifies.md) — since 2026-09-30 codex (sandbox off, confined to its worktree) implements; Claude only reviews, checks CI, merges; max 2 codex jobs at once
- [Per-agent independent commit](feedback-per-agent-independent-commit.md) — worktool: each agent = its own commit, never mixed; fan-out collects distinct commits onto the milestone branch, merge non-squash
- [Main session coordinates only](feedback-main-session-coordinates-only.md) — every edit/research via workflow; discuss with codex before asking; issue bodies frozen, updates as tagged comments; evidence on every claim; /tmp one-off only
- [Workspace layout](feedback-workspace-layout.md) — src/ only main; worktrees in worktool_ws/worktree/<name>, scratch in worktree/.scratch, codex jobs in worktool_ws/codexjobs; nothing important in /tmp
- [worktool redesign](project-worktool-distrobox-redesign.md) — distrobox-based dev-env, successor to init_ubuntu; own repo ycpss91255/worktool; milestone-gated M1-M17

## general
- [Autonomous issue/PR merge](feedback-autonomous-issue-pr-merge.md) — sub-issue PRs need no per-item approval; TDD + ci-passed + codex, then merge commit; milestone acceptance PR and release need the maintainer
- [Autonomous test-gap remediation](feedback-autonomous-test-gap-remediation.md) — don't ask to fix bugs / close test gaps; drive via workflow; only ask on product/scope forks (e.g. cutting a release tag)
- [Codex quota pause](feedback-codex-quota-pause.md) — when codex tokens run out: no codex calls, no impersonation, note gap on PRs; pause work and resume via a Monitor at the maintainer-given time
- [Folder naming](feedback-folder-all-singular.md) — all singular (doc/structure.md); only upstream-imposed + acronym exceptions
- [No personal info in scripts](feedback-no-personal-info-in-scripts.md) — never hardcode real account identifiers (emails/usernames) in scripts or comments, even as examples; read from config at runtime, keep comments generic
- [Local tests only what changed](feedback-phase-agent-run-all-ci-gates.md) — local runs lint + touched specs only (#298/#299); every full tier runs in CI; on red CI check `gh pr checks` for WHICH job first
- [Prefer hook over memory](feedback-prefer-hook-over-memory.md) — process rules go to hooks (ADR for why); memory only when a hook can't enforce
- [feedback-remote-cmd-write-script-copy-run](feedback-remote-cmd-write-script-copy-run.md) — For non-trivial remote ops, write a script file, copy it to the remote /tmp, then run it there — do NOT inline in ssh '...'
- [feedback-research-priority-agy-codex-claude](feedback-research-priority-agy-codex-claude.md) — Research/lookup: ambiguity -> research first; priority agy (gemini) -> codex -> claude sub-agent as last resort; requests to gemini must be explicit
- [feedback-subagent-no-background-verify](feedback-subagent-no-background-verify.md) — 派工 subagent 的 prompt 必須禁止用 run_in_background 跑最終驗證 — agent 回合結束即死,會卡在「standby 等測試」沒 push/沒開 PR
- [Unify formats](feedback-unify-formats.md) — never maintain two parallel sources of truth for the same fact; unify
- [Use Monitor for CI](feedback-use-monitor-for-ci.md) — never poll CI / long jobs; use Monitor tool for streaming events
- [CI lint covers bats](project-ci-lint-covers-bats.md) — lint runs shellcheck -x on *.bats too (info severity); validate bats files with shellcheck before PR, prefer `VAR=val run ...` over a standalone `export` in @test bodies
- [Branch protection convention](project-classic-branch-protection-convention.md) — ycpss91255* repos govern main via classic protection + ci-passed aggregator, not rulesets
- [RAM-crisis postmortem](project-workflow-concurrency-ram-cap.md) — the 30GB hog was runaway tmux-powerline, NOT the workflows; check /proc/PID/cmdline before blaming Docker; CPU, not RAM, caps concurrent workflows; failed runs can orphan containers (clean by prefix, never prune)
- [Workflow long-implement no schema](project-workflow-long-implement-no-schema.md) — long implement stages fail to emit StructuredOutput and error the run; give implement no schema + hardcoded branch + commit, locate worktree by branch in later stages
- [gh OAuth token limits](reference-gh-oauth-token-limits.md) — gho_ token can GET/DELETE rulesets but not PATCH; classic branch protection PUT works
- [User profile](user-profile.md) — single-maintainer, personal-use, multi-platform (x86_64 / rpi4 / rpi5 / jetson)
