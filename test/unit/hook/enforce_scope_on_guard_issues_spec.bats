#!/usr/bin/env bats
# test/unit/hook/enforce_scope_on_guard_issues_spec.bats -
# .agents/hook/enforce_scope_on_guard_issues.sh
#
# Issue #238: a guard-type issue (a hook, gate, check, filter, block or
# guard; 攔截 / 檢查 / 過濾) must state its threat model in a "## 範圍"
# section before it is filed, so the codex re-verification judges against
# a fixed scope instead of discovering it round by round. `gh issue create`
# for such an issue without the section is DENIED (permissionDecision
# "deny", exit 0); a guard issue with the section and a non-guard issue
# pass silently. The body is read from --body / -b or --body-file / -F.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

_check() { run_hook enforce_scope_on_guard_issues "$(hook_json "$1")"; }

# _check_in <cwd> <command> - the payload carries the tool call's cwd.
_check_in() {
    run_hook enforce_scope_on_guard_issues \
        "$(jq -n --arg c "$2" --arg d "$1" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')"
}

_decision() { jq -r '.hookSpecificOutput.permissionDecision' <<<"${output}"; }

setup() {
    NO_SCOPE="${BATS_TEST_TMPDIR}/no_scope.md"
    WITH_SCOPE="${BATS_TEST_TMPDIR}/with_scope.md"
    NEW_HOOK="${BATS_TEST_TMPDIR}/new_hook.md"
    printf '## 背景\n\nx\n\n## What needs to be done\n\n1. tidy the docs\n' > "${NO_SCOPE}"
    printf '## 背景\n\nx\n\n## 範圍\n\n- 擋:a\n- 不擋:b\n- 已知限制:c\n' > "${WITH_SCOPE}"
    printf '## 背景\n\nx\n\n## What needs to be done\n\n1. add a new hook that denies y\n\n## Acceptance criteria\n\n- z\n' > "${NEW_HOOK}"
}

# --- denied ------------------------------------------------------------------

@test "denies a guard-titled issue (hook) whose body file has no ## 範圍 section" {
    _check "gh issue create -R ycpss91255/worktool --title 'feat(hook): deny x' --label enhancement --body-file ${NO_SCOPE}"
    assert_success
    assert_output --partial "## 範圍"
    run _decision
    assert_output "deny"
}

@test "denies each guard title word: gate, check, filter, block, guard, 攔截, 檢查" {
    local _t
    for _t in 'ci gate for y' 'add a check for y' 'filter y' 'block y' 'guard y' '攔截 y' '檢查 y'; do
        _check "gh issue create -R ycpss91255/worktool --title '${_t}' --label bug --body-file ${NO_SCOPE}"
        run _decision
        assert_output "deny"
    done
}

@test "denies a neutral title when 'What needs to be done' asks for a new hook" {
    _check "gh issue create -R ycpss91255/worktool --title 'tidy y' --label enhancement --body-file ${NEW_HOOK}"
    run _decision
    assert_output "deny"
}

@test "reads the body from -F, --body-file=, --body, -b and the title from -t / --title=" {
    _check "gh issue create -R ycpss91255/worktool -t 'hook y' -l bug -F ${NO_SCOPE}"
    run _decision
    assert_output "deny"
    _check "gh issue create -R ycpss91255/worktool --title='hook y' -l bug --body-file=${NO_SCOPE}"
    run _decision
    assert_output "deny"
    _check "gh issue create -R ycpss91255/worktool --title 'hook y' -l bug --body 'no scope here'"
    run _decision
    assert_output "deny"
    _check "gh issue create -R ycpss91255/worktool --title 'hook y' -l bug -b 'no scope here'"
    run _decision
    assert_output "deny"
}

@test "resolves a relative body file against the tool call's cwd" {
    cp "${NO_SCOPE}" "${BATS_TEST_TMPDIR}/rel.md"
    _check_in "${BATS_TEST_TMPDIR}" "gh issue create -R ycpss91255/worktool --title 'hook y' -l bug --body-file rel.md"
    run _decision
    assert_output "deny"
}

@test "denies a stdin body (-F -, --body-file -, --body-file=-) that has no ## 範圍 section" {
    local _f
    for _f in '-F -' '--body-file -' '--body-file=-'; do
        _check "printf '## 背景\\nx\\n' | gh issue create -R ycpss91255/worktool --title 'hook y' -l bug ${_f}"
        run _decision
        assert_output "deny"
    done
}

@test "denies a stdin heredoc body without ## 範圍 and allows one that has it" {
    _check "$(printf "gh issue create -R ycpss91255/worktool --title 'hook y' -l bug -F - <<'EOF'\n## 背景\n\nx\nEOF")"
    run _decision
    assert_output "deny"
    _check "$(printf "gh issue create -R ycpss91255/worktool --title 'hook y' -l bug -F - <<'EOF'\n## 背景\n\nx\n\n## 範圍\n\n- 擋:a\nEOF")"
    assert_success
    assert_output ""
}

@test "denies a printf-pipe stdin body even when it spells ## 範圍: only a heredoc on the gh line is read" {
    _check "printf '## 背景\\nx\\n## 範圍\\n- 擋:a\\n' | gh issue create -R ycpss91255/worktool --title 'hook y' -l bug -F -"
    run _decision
    assert_output "deny"
}

@test "a ## 範圍 header forged in a comment after the gh launch is not the stdin body" {
    _check "printf 'no scope' | gh issue create -R ycpss91255/worktool --title 'hook x' -F - # \\n## 範圍"
    run _decision
    assert_output "deny"
    _check "$(printf "gh issue create -R ycpss91255/worktool --title 'hook x' -F - # <<EOF\n## 範圍\nEOF")"
    run _decision
    assert_output "deny"
}

@test "a quoted << on the gh line does not open a heredoc body" {
    _check "$(printf "gh issue create -R ycpss91255/worktool --title 'hook <<X' -F -\n## 範圍\nX")"
    run _decision
    assert_output "deny"
}

@test "a ## 範圍 header elsewhere in the command is not the stdin body" {
    _check "$(printf "cat > /tmp/s.md <<'EOF'\n## 範圍\nEOF\ngh issue create -R ycpss91255/worktool --title 'hook x' -F - <<'EOF'\n## 背景\nEOF")"
    run _decision
    assert_output "deny"
    _check "$(printf "echo '## 範圍'; gh issue create -R ycpss91255/worktool --title 'hook x' -F - <<'EOF'\n## 背景\nEOF")"
    run _decision
    assert_output "deny"
}

@test "a heredoc that does not reach gh's stdin is not the body (2<<, a later < file, a second launch)" {
    _check "$(printf "gh issue create -R ycpss91255/worktool --title 'hook x' -F - 2<<'EOF'\n## 範圍\nEOF")"
    run _decision
    assert_output "deny"
    _check "$(printf "gh issue create -R ycpss91255/worktool --title 'hook x' -F - <<'EOF' < /dev/null\n## 範圍\nEOF")"
    run _decision
    assert_output "deny"
    _check "$(printf "gh issue create -R ycpss91255/worktool --title 'hook x' -F - <<'EOF'\n## 範圍\nEOF\ngh issue create -R ycpss91255/worktool --title 'hook z' -F - <<'EOF'\nno\nEOF")"
    run _decision
    assert_output "deny"
}

@test "allows a heredoc body after backslash-continued options and a <<- heredoc with tabs" {
    _check "$(printf "gh issue create -R ycpss91255/worktool \\\\\\n  --title 'hook y' -l bug -F - <<'EOF'\n## 範圍\n- 擋:a\nEOF")"
    assert_success
    assert_output ""
    _check "$(printf "gh issue create -R ycpss91255/worktool --title 'hook y' -F - <<-EOF\n\t## 範圍\n\t- 擋:a\n\tEOF")"
    assert_success
    assert_output ""
}

@test "denies a stdin body the hook cannot see (piped from a file), even when the file has ## 範圍" {
    _check "cat ${WITH_SCOPE} | gh issue create -R ycpss91255/worktool --title 'hook y' -l bug -F -"
    run _decision
    assert_output "deny"
}

# --- allowed -----------------------------------------------------------------

@test "allows a guard issue whose body has a ## 範圍 section" {
    _check "gh issue create -R ycpss91255/worktool --title 'feat(hook): deny x' --label enhancement --body-file ${WITH_SCOPE}"
    assert_success
    assert_output ""
    _check "gh issue create -R ycpss91255/worktool --title 'hook y' -l bug -F ${WITH_SCOPE}"
    assert_output ""
}

@test "allows an ordinary issue without a ## 範圍 section" {
    _check "gh issue create -R ycpss91255/worktool --title 'docs: tidy the readme' --label documentation --body-file ${NO_SCOPE}"
    assert_success
    assert_output ""
}

@test "guard words match whole words only (checkout, hooked-up text is not a guard)" {
    _check "gh issue create -R ycpss91255/worktool --title 'docs: checkout steps' --label documentation --body-file ${NO_SCOPE}"
    assert_output ""
}

@test "a 'new hook' outside 'What needs to be done' does not make the issue guard-type" {
    printf '## 背景\n\nwe once added a new hook\n\n## What needs to be done\n\n1. tidy docs\n' > "${BATS_TEST_TMPDIR}/bg.md"
    _check "gh issue create -R ycpss91255/worktool --title 'docs: tidy' --label documentation --body-file ${BATS_TEST_TMPDIR}/bg.md"
    assert_output ""
}

@test "other gh subcommands, quoted mentions and non-gh commands pass" {
    _check "gh issue edit 5 -R ycpss91255/worktool --title 'hook y'"
    assert_output ""
    _check "git commit -m 'gh issue create --title hook --body x'"
    assert_output ""
    _check "git status"
    assert_output ""
}

@test "the guard rule lives in one function" {
    run grep -c '^_is_guard_issue()' "${HOOK_DIR}/enforce_scope_on_guard_issues.sh"
    assert_output "1"
}
