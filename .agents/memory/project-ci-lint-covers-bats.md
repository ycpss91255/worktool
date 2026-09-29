---
name: project-ci-lint-covers-bats
description: "CI lint runs shellcheck -x on *.bats too; validate bats files, not just .sh, before integrating"
metadata: 
  node_type: memory
  type: project
  originSessionId: 15320221-f6f9-442e-9faa-924d66c5db63
---

The `lint` gate (`just test lint`, which runs `script/test/test.sh --lint`
-> ShellCheck in the test container) checks `*.sh` AND `*.bats`
(`shellcheck -x --shell=bash`), at shellcheck's default severity (info
included). So an info-level finding in a `.bats` file (e.g. SC2030/SC2031)
fails the lint job even though all bats TESTS pass.

**Why:** a standalone `export VAR=...` inside an `@test` body is "modification
local to the bats subshell" (SC2030), and a later read is SC2031. The passing
convention is the inline command-prefix form: `VAR=val run cmd ...`, which is
scoped to the command and not flagged.

**How to apply:** when an agent adds/edits `.bats` files, run `just test lint`
BEFORE opening the PR — the unit/integration gates do not run ShellCheck, and
the finding surfaces only as a red `lint` job. Prefer `VAR=val run ...` over a
standalone `export VAR=...` in test bodies. worktool keeps zero
`shellcheck disable` directives (AGENTS.md shell conventions). Relates to
[[feedback-autonomous-test-gap-remediation]].
