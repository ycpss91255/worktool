---
name: wait-pr-ci
description: Wait for a PR's GitHub CI to settle via the Monitor tool (one notification per state change) instead of busy-polling with sleep loops.
---

# wait-pr-ci

Wait for CI to finish on one or more PRs with `Monitor`, so each state change streams in as a notification and the agent is not blocked on `sleep` loops. The poll loop lives in `.claude/script/wait-pr-ci.sh` (a symlink to `.agents/script/wait-pr-ci.sh`), so the Monitor command stays one line.

## Usage

```
Monitor(
  description: "PR #<num> CI",
  command: ".claude/script/wait-pr-ci.sh --repo ycpss91255/worktool --prs <CSV>",
  timeout_ms: 2400000,     # the test-system-real job alone may take up to 40 min
  persistent: false,       # the script exits on ALL_DONE / FAIL
)
```

`--help` prints every option. The relative path resolves against the agent's cwd: run it from the repo root or from a worktree under `.worktree/` (each carries `.claude/`). `${CLAUDE_PROJECT_DIR}` is only set for hooks, not for Bash / Monitor commands.

## What it watches

worktool's branch protection requires exactly one check: the `ci-passed` aggregator in `.github/workflows/ci.yml`, which is green only when every gate on both architectures is green. That is the default filter (`--check-filter '.name=="ci-passed"'`), so the default is right for every worktool PR; `--check-filter <jq-expr>` narrows to other checks when needed.

## Output and exit

- One snapshot block per state change, nothing while steady:
  `PR<n>: checks=<no-checks|pending|all-pass|FAIL> mergeable=<m>` then `---`.
- `ALL_DONE`, exit 0: every PR is all-pass and MERGEABLE.
- `FAIL <pr>`, exit 1: a matching check failed - read the failing job's log (`gh pr checks <pr> --repo ycpss91255/worktool`) before retrying.
- `FAIL <pr> (mergeable=CONFLICTING)`, exit 1: main moved; rebase the branch onto `origin/main` and push, then watch again.
- Exit 2: argument error (`wait-pr-ci.sh: unknown option '<x>' (see --help)`). Exit 124: `--max-iterations` reached (tests only).
- Only `SUCCESS` passes. A completed check that is `SKIPPED`, `CANCELLED`, `TIMED_OUT` or any other conclusion is `FAIL`, the same rule `ci-passed` applies to its gates (`doc/structure.md`, CI).

## Guards

- **Subset rollup**: right after a PR opens the rollup may list only some checks. `--min-checks <N>` requires N matching checks before `all-pass` (default 1, enough for the single `ci-passed`).
- **In-progress check**: a matching check whose status is not `COMPLETED` is `pending`.
- **Force-push race**: when every matching check completed within `--stale-window` seconds (default 120) before the watch started, the rollup is taken as the previous head's result and held at `pending`; older results are trusted.
- **Head moved**: when a PR's `headRefOid` changes between polls, one `[head-moved] PR<n> <old7>..<new7>` line is printed and the PR is `pending` for that poll.

## After ALL_DONE

`ALL_DONE` only means CI is green. worktool merges a sub-issue PR only after codex has also confirmed it, with a merge commit (`gh pr merge <PR> --repo ycpss91255/worktool --merge`, never squash or auto-merge); the milestone acceptance PR is a human gate and is never merged by an agent. Afterwards run `git pull --ff-only origin main` on the main checkout.

## Anti-patterns

- `sleep 60` between manual `gh pr checks` calls: noisy context, nothing to show.
- `gh run watch`: follows one workflow run; the PR rollup already aggregates the matrix.
- Inlining the loop in the Monitor `command`: Claude Code's bash parser warns on inlined parameter expansions and here-strings; calling the script avoids it.
