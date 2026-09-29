#!/usr/bin/env bats
# test/unit/hook/enforce_gh_body_file_spec.bats - .agents/hook/enforce_gh_body_file.sh
#
# gh issue / pr creation must go through --body-file <real path>, issue
# creation must carry a --label, long comment bodies go through a file, and
# `--body "$(cat ...)"` / `--body-file -` heredocs are refused (they trip
# Claude Code's bash parser). Violations are DENIED (permissionDecision
# "deny", exit 0); canonical forms and other subcommands pass silently. The
# reasons speak worktool (-R ycpss91255/worktool, zh-TW bodies are fine)
# and cite no other repo's issue numbers.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

_check() { run_hook enforce_gh_body_file "$(hook_json "$1")"; }

_decision() { jq -r '.hookSpecificOutput.permissionDecision' <<<"${output}"; }

# --- denied ------------------------------------------------------------------

@test "denies 'gh issue create' without --body-file" {
    _check "gh issue create -R ycpss91255/worktool --title x --label bug"
    assert_success
    run _decision
    assert_output "deny"
}

@test "denies 'gh pr create' without --body-file" {
    _check "gh pr create --repo ycpss91255/worktool --title x"
    assert_success
    assert_output --partial "body-file"
    run _decision
    assert_output "deny"
}

@test "denies 'gh issue create' with a body file but no --label" {
    _check "gh issue create -R ycpss91255/worktool --title x --body-file /tmp/b.md"
    assert_success
    assert_output --partial "label"
    run _decision
    assert_output "deny"
}

@test "denies a --body \"\$(cat ...)\" substitution" {
    # The '$' is assembled separately so ShellCheck does not see a live
    # expansion in single quotes; the runtime string carries '$(cat ...)'.
    local d='$'
    _check "gh issue comment 5 --body \"${d}(cat /tmp/b.md)\""
    run _decision
    assert_output "deny"
}

@test "denies a --body-file - heredoc" {
    _check "gh pr comment 3 --body-file - <<EOF"
    run _decision
    assert_output "deny"
}

@test "denies a multi-line inline pr comment body" {
    _check "$(printf 'gh pr comment 3 --body "line one\nline two"')"
    run _decision
    assert_output "deny"
}

@test "denies gh issue close --comment (two-step close)" {
    _check "gh issue close 5 --comment done"
    run _decision
    assert_output "deny"
}

@test "deny reasons cite no other repo's issue numbers" {
    _check "gh pr create --title x"
    refute_output --partial "#64"
    _check "gh issue create --title x --body-file /tmp/b.md"
    refute_output --partial "#91"
    refute_output --partial "ISSUE_TEMPLATE"
}

# --- allowed -----------------------------------------------------------------

@test "allows 'gh issue create' with a real body file and a label" {
    _check "gh issue create -R ycpss91255/worktool --title x --body-file /tmp/b.md --label enhancement"
    assert_success
    assert_output ""
}

@test "allows 'gh pr create' with a real body file" {
    _check "gh pr create --repo ycpss91255/worktool --title x --body-file /tmp/b.md"
    assert_success
    assert_output ""
}

@test "allows a short single-line inline pr comment (<= 80 chars)" {
    _check "gh pr comment 3 --body 'looks good'"
    assert_success
    assert_output ""
}

@test "allows an out-of-scope subcommand (gh pr view)" {
    _check "gh pr view 3"
    assert_success
    assert_output ""
}

@test "allows a non-gh command" {
    _check "git status"
    assert_success
    assert_output ""
}
