#!/usr/bin/env bats
# test/unit/hook/remind_no_emoji_spec.bats - .agents/hook/remind_no_emoji.sh
#
# UserPromptSubmit, advisory only: every prompt gets the no-emoji standing
# rule as additionalContext; never blocks (exit 0). worktool does not carry
# enforce_gh_english.sh, so the text must not point at it.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

@test "injects the no-emoji rule as UserPromptSubmit additionalContext" {
    run_hook remind_no_emoji '{"prompt":"do something"}'
    assert_success
    run jq -r '.hookSpecificOutput | .hookEventName + "|" + .additionalContext' <<<"${output}"
    assert_output --partial "UserPromptSubmit|"
    assert_output --partial "NEVER use emoji"
}

@test "fires even for an empty payload" {
    run_hook remind_no_emoji ""
    assert_success
    assert_output --partial "NEVER use emoji"
}

@test "never emits a permission decision and names no hook worktool lacks" {
    run_hook remind_no_emoji '{"prompt":"x"}'
    assert_success
    refute_output --partial "permissionDecision"
    refute_output --partial "enforce_gh_english"
}
