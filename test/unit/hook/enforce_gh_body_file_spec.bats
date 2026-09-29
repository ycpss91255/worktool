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

# --- only a real gh launch counts (codex round 1 on #193) ---------------------

@test "allows quoted text that mentions gh issue create / gh pr create" {
    _check "git commit -m 'docs: explain gh issue create and gh pr create --body x'"
    assert_success
    assert_output ""
    _check "echo \"run gh pr create --title x\""
    assert_success
    assert_output ""
}

@test "allows a heredoc body that mentions gh issue create" {
    _check "$(printf 'cat > /tmp/b.md <<EOF\ngh issue create --title x\nEOF')"
    assert_success
    assert_output ""
}

@test "judges the gh launch, not quoted text before it" {
    _check "echo 'gh pr create' && gh pr comment 3 --body 'looks good'"
    assert_success
    assert_output ""
    _check "echo ok && GH_TOKEN=x gh pr create --title x"
    run _decision
    assert_output "deny"
}

@test "allows non-gh commands silently, even with gh-like words" {
    _check "ls -la"
    assert_success
    assert_output ""
    _check "grep -rn 'gh issue create' doc"
    assert_success
    assert_output ""
}

# --- each gh launch is judged on its own text (codex round 2 on #193) ---------

@test "a substitution in another sub-command's quoted data does not deny a gh launch" {
    local d='$'
    _check "gh pr view 3 && git commit -m \"note: --body ${d}(cat f) is refused\""
    assert_success
    assert_output ""
    _check "gh pr view 3 && echo '--body \"${d}(cat f)\"'"
    assert_success
    assert_output ""
}

@test "a long body elsewhere in the command does not deny a short gh comment" {
    local long
    long="$(printf 'x%.0s' {1..120})"
    _check "echo --body '${long}' && gh pr comment 3 --body 'looks good'"
    assert_success
    assert_output ""
    _check "gh pr comment 3 --body 'looks good' && gh issue comment 4 --body '${long}'"
    assert_output --partial "gh issue comment body is too long"
    run _decision
    assert_output "deny"
}

@test "still denies a substitution inside the gh launch's own body" {
    local d='$'
    _check "ls && gh pr comment 3 --body \"see ${d}(cat /tmp/b.md)\""
    run _decision
    assert_output "deny"
}
