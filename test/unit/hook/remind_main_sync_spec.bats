#!/usr/bin/env bats
# test/unit/hook/remind_main_sync_spec.bats - .agents/hook/remind_main_sync.sh
#
# Advisory-only PreToolUse Bash hook (never blocks, exit 0). On a real
# `gh pr merge` it reminds to ff-pull local main afterwards. worktool merges
# a PR with a merge commit (`--merge`) once CI is green and codex confirmed,
# keeping every agent's commits - so a `--squash` / `--rebase` merge or an
# `--auto` queue also gets a note saying so. A `gh pr merge` inside quoted
# text must not trigger it.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

_check() { run_hook remind_main_sync "$(hook_json "$1")"; }

# Print the additionalContext of the hook's JSON output.
_context() { jq -r '.hookSpecificOutput.additionalContext' <<<"${output}"; }

@test "nested gh pr merge -> immediate advisory reminder" {
    local command
    for command in "bash -c 'gh pr merge 42 --merge'" "eval 'gh pr merge 42 --merge'"; do
        _check "${command}"
        assert_success
        run _context
        assert_output --partial "pull --ff-only origin main"
        assert_output --partial "[variant=immediate]"
    done
}

@test "gh pr merge --merge -> immediate reminder to ff-pull main, no merge-mode note" {
    _check "gh pr merge 42 --repo ycpss91255/worktool --merge"
    assert_success
    run _context
    assert_output --partial "pull --ff-only origin main"
    assert_output --partial "[variant=immediate]"
    refute_output --partial "merge commit"
}

@test "gh pr merge --squash -> reminder plus the merge-commit note" {
    _check "gh pr merge --squash 42"
    assert_success
    run _context
    assert_output --partial "pull --ff-only"
    assert_output --partial "merge commit"
}

@test "gh pr merge --rebase -> the merge-commit note too" {
    _check "gh pr merge 42 --rebase"
    assert_success
    run _context
    assert_output --partial "merge commit"
}

@test "gh pr merge --auto -> queued variant and a note that worktool does not auto-merge" {
    _check "gh pr merge --auto --merge 42"
    assert_success
    run _context
    assert_output --partial "[variant=queued]"
    assert_output --partial "codex"
}

@test "gh pr merge after && still fires" {
    _check "gh pr checks 42 && gh pr merge --merge 42"
    assert_success
    assert_output --partial "pull --ff-only"
}

@test "gh pr view -> silent" {
    _check "gh pr view 42"
    assert_success
    assert_output ""
}

@test "a commit message containing 'gh pr merge' does NOT trigger (quoted)" {
    _check "git commit -m 'note: run gh pr merge --squash after CI'"
    assert_success
    assert_output ""
}

@test "empty command -> silent" {
    _check ""
    assert_success
    assert_output ""
}

@test "main sync advisory allows when JSON emission fails" {
    run bash -c 'jq() { if [[ "$1" == -n ]]; then return 7; fi; command jq "$@"; }; export -f jq; printf "%s" "$1" | "$2"' _ \
        "$(hook_json 'gh pr merge 42 --merge')" "${HOOK_DIR}/remind_main_sync.sh"
    assert_success
}

@test "successful PostToolUse merge runs cleanup with apply and reports removals" {
    local project="${BATS_TEST_TMPDIR}/project"
    mkdir -p "${project}/.agents/script/worktree"
    cat > "${project}/.agents/script/worktree/prune-merged.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --apply ]]
printf 'removed worktree: fixture\n' >&2
SCRIPT
    chmod +x "${project}/.agents/script/worktree/prune-merged.sh"
    local payload
    payload="$(hook_json 'gh pr merge 42 --repo ycpss91255/worktool --merge' | \
        jq --arg cwd "${project}" '. + {hook_event_name:"PostToolUse", cwd:$cwd, tool_response:{exit_code:0}}')"
    run_hook remind_main_sync "${payload}"
    assert_success
    assert_output --partial "removed worktree: fixture"
    assert_output --partial "PostToolUse"
}

@test "post merge cleanup skips failures auto queues help and unconfirmed results" {
    local command response payload
    for command in 'gh pr merge 42 --merge' 'gh pr merge 42 --auto' 'gh pr merge --help'; do
        for response in '{"exit_code":1}' '{}' '{"exit_code":0}'; do
            [[ "${command}" == 'gh pr merge 42 --merge' && "${response}" == '{"exit_code":0}' ]] && continue
            payload="$(hook_json "${command}" | jq --argjson response "${response}" \
                '. + {hook_event_name:"PostToolUse", cwd:"/nonexistent", tool_response:$response}')"
            run_hook remind_main_sync "${payload}"
            assert_success
            assert_output ""
        done
    done
}

@test "post merge recognizes the repository root flag before pr merge" {
    local payload
    payload="$(hook_json 'gh --repo ycpss91255/worktool pr merge 42 --merge' | \
        jq '. + {hook_event_name:"PostToolUse", cwd:"/nonexistent", tool_response:{exit_code:0}}')"
    run_hook remind_main_sync "${payload}"
    assert_success
    assert_output --partial "Worktree cleanup failed"
}

@test "native Claude successful Bash response also triggers post merge cleanup" {
    local payload
    payload="$(hook_json 'gh pr merge 42 --repo ycpss91255/worktool --merge' | \
        jq '. + {hook_event_name:"PostToolUse", cwd:"/nonexistent",
            tool_response:{stdout:"", stderr:"", interrupted:false, isImage:false}}')"
    run_hook remind_main_sync "${payload}"
    assert_success
    assert_output --partial "Worktree cleanup failed"
}
