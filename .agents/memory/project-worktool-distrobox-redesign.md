---
name: project-worktool-distrobox-redesign
description: "worktool: distrobox-based dev-environment, the major redesign successor to init_ubuntu; own repo ycpss91255/worktool, milestone-gated M1-M17"
metadata:
  node_type: memory
  type: project
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
  modified: 2026-09-28T03:07:41.058Z
---

Started 2026-09-15. worktool (repo ycpss91255/worktool, private) is a ground-up
redesign and new-major-version successor to init_ubuntu. Core model (locked via
grilling): distrobox as the base; developer CLI/TUI tools live in ONE shared
"dev" box that the maintainer LIVES IN (terminal auto-enters via distrobox enter);
configs stay in the shared HOME (distrobox shares HOME); the host keeps only
drivers (nvidia/kvm), docker, snapd, desktop GUI apps (as install scripts under
tool/, NOT modules), and the container framework. The old 10-function
apt-archetype module system dissolves into (a) host install scripts + (b) the box
package manifest (distrobox-assemble native INI format, base ubuntu:26.04).
Front-end: setup_ubuntu CLI + fzf TUI are retired; a brand-new front-end is
designed in M13/M14. init_ubuntu stays working until cutover.

**Governance (maintainer-set):** milestone-based M1-M17, sequential, no skipping;
HUMAN REVIEW GATE between every milestone (present PR, do NOT auto-merge; the user
approves, then merge, then unlock/start the next). **ONE ISSUE = ONE PR, one PR
does ONE thing (maintainer correction 2026-09-19, after a 23-commit M2 PR):** a
milestone is many small PRs, each for one sub-issue, each merged autonomously once
/tdd + CI green + codex confirm; ONLY the final "milestone acceptance" PR (checklist
doc + Closes parent issue) is the human gate the user approves. Size sub-issues so
each is one PR. Never accumulate a milestone on one branch. **Parallelize whatever
is independent (maintainer 2026-09-19 "可以並行處理的就並行處理"):** independent
sub-issues = independent branches off main + parallel PRs/CI/codex, merge as each
goes green; stack only true dependencies. While a milestone gate waits on the user,
run the NEXT milestone's research (agy) in parallel but open no implementation PRs. Within a milestone: autonomous,
robustness+stability first. Only the FINAL milestone's release + major decisions
need human consent. Performance is a first-class NFR (shell entry < ~300ms, tool
invocation overhead < ~50-100ms). Full test pyramid required per milestone (unit
/ integration / system / acceptance), Docker-only; real-hardware acceptance via a
human checklist in doc/acceptance.md. Every issue/PR + design doc in zh-TW;
commits/code in English.

**Tracking:** epic issue #1; each milestone = a GitHub Milestone + a parent issue
(#3-#19) + sub-issues (M3-M17: per-tool for porting milestones, ~95 total; M1/M2
backfilled). Each parent carries a 驗收標準 section. Future milestones' issues
stay unlocked but gated by the human review gate (issue-lock was tried then
dropped). Stack: bash + bats + just + GitHub Actions + Docker (mirrors init_ubuntu).

**STATUS 2026-09-19:** M1 merged (PR #2). **M2 DONE**: the 23-commit PR #20 was
closed and re-landed as 12 one-issue PRs #135-#146 (stacked, sequential, each
CI green + codex "可合併"), then the docs-only gate PR #147 (checklist in
doc/acceptance.md M2 section) was accepted by the user (all items incl. 7.1 on a
real host) and merged; #4 closed; M3 (#5 + subs #21-#24) unlocked. Branch
protection on main: ci-passed required + strict + enforce_admins, no review
requirement, no linear-history (merge commits keep agent commits). Open decision
issues: #22 (needs-decision: docker runc vs crun for < 300 ms; research says
default distrobox enter is ~395 ms, needs warm box + crun + lean fish), #148
(needs-decision: arm64 CI = hosted ubuntu-24.04-arm recommended; second Ubuntu =
24.04 LTS recommended). Next: M3 (auto-enter + latency) with parallel sub-issue
PRs; add an arm64 CI job early in M3.

**STATUS 2026-09-28:** M3 shipped as 10 one-issue PRs (#152-#156 + follow-ups
#165-#169, all codex-mergeable); #22 closed out by measurement (real host fish:
enter median 184.6 ms, shell 186.7 ms, inbox 18.8 ms; CI DinD 123.5 / 145.2 /
7.8 ms) so runc stays, no crun. Gate PR #157 is the human gate and is NOT
merged: the maintainer ran codex on it and posted "不建議 merge" with 10
findings, all against the CHECKLIST itself (not the code) -> fixed in cebcd22,
CI 15/15. Durable rule set from that round lives in the non-git
worktool-ACCEPTANCE-REQUIREMENTS.md section G (dependency split, self-contained
backup/restore + `distrobox rm -f`, external-evidence blocks must rc!=0 on query
failure and be negative-tested with a failing fake gh, mktemp guard + trap, no
fixed /tmp paths, exact-set assertions, `wc -l` on an empty here-string lies).
Still open on the gate: 5.1 (real-host bench numbers must be posted to #22) and
5.2 (needs a host with ghostty).

**`just` = THE user interface, modelled on ycpss91255-docker/base (maintainer
decisions 2026-09-16 at the M2 gate):** base ADR-00000005/10/11 command model:
(1) zero special cases - every action is a `mod?` namespace, root justfile = mod?
lines + `default: @just --list` (bare `just` lists namespaces); (2) action-named
namespaces (`test`, `box`; never ci/cd); (3) min->max - bare `just test` runs
everything, sub-recipes/flags narrow; (4) justfiles are THIN forwarders (`*args`
verbatim); validation, usage, `--help` live in the SCRIPTS - a justfile must never
print usage / "valid: ..." lists (the maintainer: "just 不應該直接拋出 help 的資訊");
(5) each module has `default` + `help` (alias h) + `set working-directory := '../..'`.
Layout: script/test/{test.sh,justfile.test,selfcheck.sh,system-real-entry.sh},
script/box/{assemble.sh,justfile.box}. Commands: `just test [build|lint|unit|
integration|system|system-real|acceptance|selfcheck|help]`, `just box assemble
[--dry-run] [--file X]`, `just box help`. Each milestone's new user action = recipe in
the right namespace + justfile spec case + script owning `--help`; acceptance
checklists use `just ...`. A first flat design (`just test [tier]` with validation in
the justfile, `just assemble [mode] [file]`) was replaced the same day - check base
BEFORE designing any CLI surface. `just` was inherited from init_ubuntu (ADR-0022)
with no worktool-level decision until the maintainer raised it ("腳本呼叫很麻煩").

**Acceptance-description FORMAT (maintainer-mandated 2026-09-16 on PR #20, use
for EVERY milestone):** `## 通用指令` (clone etc.) then `## 驗收項目` as nested
checkboxes: `- [ ] 大項目` -> `- [ ] 小項目, 驗收標準` -> `- 預期看到資訊` ->
`- 驗收方式` + ```bash block```. Every 預期看到資訊 must be captured from a real
run, and (maintainer 2026-09-19 "字太多了") shown VERBATIM in a ```text block
(head/tail kept, middle elided with `...(全部 ok)`), criteria one line, commands in
```bash blocks, no explanatory prose and no long inline-backtick output strings. Non-git requirements file: worktool-ACCEPTANCE-REQUIREMENTS.md in the workspace's `note/` directory (next to the checkout, outside git)
(sections A-I; G = user-flagged gaps with status). Milestone roadmap:
M3 auto-enter+perf, M4 host bootstrap, M5-M10 box tools (importance order:
shell -> nav/file -> editor/git -> runtime/AI -> monitoring -> rest),
M11-M12 host drivers+GUI scripts, M13-M14 new front-end, M15 full test pyramid,
M16 docs + migration, M17 release 2.0.0.

**gh --repo hygiene (gotcha, 2026-09-15):** ALWAYS pass `--repo <owner/name>` on
every `gh issue`/`gh pr` call in a script, especially locks/edits. A sub-issue
script ran `gh issue lock <n>` WITHOUT --repo from an initialization cwd, so it
silently locked initialization issues at the same numbers (55 of them) instead of
the worktool sub-issues. Cleanup: lock worktool subs with --repo + unlock the
accidental initialization locks. worktool issue-lock model: M1/M2 (#3/#4) and their
subs stay unlocked; M3-M17 parents (#5-#19) + their 95 subs stay locked; unlock the
next milestone's parent+subs after each human gate.

Related: [[feedback-codex-claude-collab]], [[feedback-per-agent-independent-commit]],
[[feedback-autonomous-issue-pr-merge]], [[feedback-codex-round-stop-rule]].

**Workspace layout (updated 2026-10-01):** one workspace directory holds `src/`
(the main-only checkout), `worktree/<name>` (the pr-loop workflow and the
WorktreeCreate hook both use it), and `note/` (non-git:
ACCEPTANCE-REQUIREMENTS.md, M3 handoffs). Agent scratch lives under
`worktree/.scratch/<name>`. Machine paths are not recorded here; they differ per
host.
