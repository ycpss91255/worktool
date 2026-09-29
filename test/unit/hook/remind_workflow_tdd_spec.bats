#!/usr/bin/env bats
# test/unit/hook/remind_workflow_tdd_spec.bats - .agents/hook/remind_workflow_tdd.sh
#
# UserPromptSubmit, advisory only: every prompt gets worktool's standing
# delivery directive as additionalContext (never a permission decision,
# exit 0). The directive is worktool's loop, not initialization's: the
# pr-loop / milestone-fanout workflows, TDD with `just test <tier>` in
# Docker, one issue one PR, CI green + codex confirmation, merge commit
# (no squash, no auto-merge), milestone acceptance PR = human gate.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

_context() { jq -r '.hookSpecificOutput | .hookEventName + "|" + .additionalContext' <<<"${output}"; }

@test "injects the directive as UserPromptSubmit additionalContext" {
    run_hook remind_workflow_tdd '{"prompt":"build a feature"}'
    assert_success
    run _context
    assert_output --partial "UserPromptSubmit|"
    assert_output --partial "TDD"
}

@test "the directive is worktool's delivery loop" {
    run_hook remind_workflow_tdd '{"prompt":"x"}'
    run _context
    assert_output --partial "pr-loop"
    assert_output --partial "milestone-fanout"
    assert_output --partial "just test"
    assert_output --partial "codex"
    assert_output --partial "merge commit"
    assert_output --partial "human gate"
}

@test "the directive does not carry initialization's auto-merge loop" {
    run_hook remind_workflow_tdd '{"prompt":"x"}'
    run _context
    refute_output --partial "dual-watch"
    refute_output --partial "auto-merge Monitor"
}

@test "fires even for an empty payload and never blocks" {
    run_hook remind_workflow_tdd ""
    assert_success
    assert_output --partial "additionalContext"
    refute_output --partial "permissionDecision"
}
