---
name: feedback-phase-agent-run-all-ci-gates
description: Local tests cover only what the change touches (lint + touched specs); every full tier runs in GitHub CI (ci-passed). Superseded the old "run all six gates locally" rule on 2026-10-01
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
  modified: 2026-10-01T09:46:44.541Z
---

The pre-push local gate is defined once, in ADR-0014 decision 2; this note
only points at it. In short: `just test lint` plus the specs the change adds or
edits, in whichever tier they live (`just test <tier> <spec...> [--filter
REGEX]`, #298), leaving `test/system-real/` and
`test/system/real_engine_spec.bats` to CI. Since 2026-11-09 (#756) `just test
changed` is not run before pushing (it stays an optional command a caller may
request explicitly). Every full tier (unit, matrix, integration, system,
acceptance, system-real) runs in GitHub CI, where `ci-passed` is required.
Never run a whole tier locally, per TDD slice or before pushing.

**Why:** maintainer decision 2026-10-01 ("local 針對修改的地方做 test 就好,
其他都丟到 ci 上面做測試"). Two codex jobs each running the full unit tier
(about 1000 cases, bats --jobs 4) per RED and GREEN drove an 8-core host to a
load of 36. The architecture copies ycpss91255-docker/base (`--bats-path`,
`--filter`) and keeps vendor_kit ADR-0011/0013 (same entry locally and in CI,
no env-var mode switch). The old rule (run all six gates locally) came from
init_ubuntu, where a skipped tier hid a break; CI's required `ci-passed`
covers that now.

**How to apply:** implementation prompts say "in the TDD loop run only the
slice's spec; before pushing run `just test lint` and the specs you add or
change, in whatever tier (`just test <tier> <spec> [--filter]`), except
system-real; never a whole tier and never `just test changed`; CI runs
everything" (the default pr-loop gate runs the same set). NEVER tell an agent
to run "the matrix specs that exercise this lib" when the change did not edit
them -- on 2026-10-01 that wording made two codex jobs run the 81-case approval
matrix locally for 40-50 minutes each and saturated the host. #326 added
`enforce_local_test_scope.sh` against it; since #800 it applies ADR-0014
decision 2 to literal arguments: an explicit spec of any tier except
system-real runs, while a whole tier, the real-engine group and a bare
every-tier run are blocked. Since #818 spec/tier arguments the shell expands
(glob, brace, $VAR, $(...)) are blocked too, since they may select a whole
tier the hook cannot see. Filter/base values stay data when their quoting
proves one argv (#902); unquoted splitting values and quoted positional/array
@ remain blocked. Write each touched spec as a literal path and quote a
--filter regex. A literal list that happens to name every spec of a tier is taken as
touched specs and allowed (decision 2 allows any tier's touched specs, and
test/acceptance has a single spec). A 30-minute audit cron stops any such run. On a
red CI job, check `gh pr checks <n> -R ycpss91255/worktool` first to see
WHICH job (and runner leg) failed. Relates to
[[feedback-autonomous-test-gap-remediation]] and [[project-ci-lint-covers-bats]].
