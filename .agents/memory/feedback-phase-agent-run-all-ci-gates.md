---
name: feedback-phase-agent-run-all-ci-gates
description: Local tests cover only what the change touches (lint + touched specs); every full tier runs in GitHub CI (ci-passed). Superseded the old "run all six gates locally" rule on 2026-10-01
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
  modified: 2026-10-01T00:13:18.857Z
---

Local test runs cover only what the change touches: `just test lint` plus the
specs the change adds or edits (`just test <tier> <spec...> [--filter REGEX]`,
#298), and before pushing `just test changed` (#299). Every full tier (unit,
matrix, integration, system, acceptance, system-real) runs in GitHub CI, where
`ci-passed` is required. Never run a whole tier locally per TDD slice.

**Why:** maintainer decision 2026-10-01 ("local 針對修改的地方做 test 就好,
其他都丟到 ci 上面做測試"). Two codex jobs each running the full unit tier
(about 1000 cases, bats --jobs 4) per RED and GREEN drove an 8-core host to a
load of 36. The architecture copies ycpss91255-docker/base (`--bats-path`,
`--filter`) and keeps vendor_kit ADR-0011/0013 (same entry locally and in CI,
no env-var mode switch). The old rule (run all six gates locally) came from
init_ubuntu, where a skipped tier hid a break; CI's required `ci-passed`
covers that now.

**How to apply:** implementation prompts say "TDD loop: run only the slice's
spec; before push: lint + `just test changed`; everything else is CI". Until
#298/#299/#300 merge, run `just test lint` and `just test unit` with
`WORKTOOL_TEST_JOBS=2` at most once per slice, one codex job at a time. On a
red CI job, check `gh pr checks <n> -R ycpss91255/worktool` first to see
WHICH job (and runner leg) failed. Relates to
[[feedback-autonomous-test-gap-remediation]] and [[project-ci-lint-covers-bats]].
