#!/usr/bin/env bats
# Fast representative coverage; complete products live in test/matrix.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    MAIN_REPO="${BATS_TEST_TMPDIR}/main"
    LINKED_REPO="${MAIN_REPO}/.worktree/linked"
    mkdir -p "${MAIN_REPO}"
    git -C "${MAIN_REPO}" init -q
    git -C "${MAIN_REPO}" config user.email test@example.com
    git -C "${MAIN_REPO}" config user.name Test
    printf 'base\n' >"${MAIN_REPO}/tracked.txt"
    git -C "${MAIN_REPO}" add tracked.txt
    git -C "${MAIN_REPO}" commit -qm base
    git -C "${MAIN_REPO}" worktree add -q -b linked "${LINKED_REPO}"
    mkdir -p "${MAIN_REPO}/.agents/memory"
}

_payload() {
    jq -n --arg tool "$1" --arg value "$2" --arg cwd "$3" '{
        cwd:$cwd, tool_name:$tool,
        tool_input:if $tool == "Bash" then {command:$value} else {file_path:$value} end
    }'
}

@test "representative file locations and edit tools follow the read-only rule" {
    run_hook enforce_main_checkout_readonly "$(_payload Edit "${MAIN_REPO}/blocked" "${MAIN_REPO}")"
    assert_failure 2
    run_hook enforce_main_checkout_readonly "$(_payload Write "${LINKED_REPO}/allowed" "${MAIN_REPO}")"
    assert_success
    run_hook enforce_main_checkout_readonly "$(_payload MultiEdit "${MAIN_REPO}/.agents/memory/note" "${MAIN_REPO}")"
    assert_success
    run_hook enforce_main_checkout_readonly "$(_payload Edit "${BATS_TEST_TMPDIR}/outside" "${MAIN_REPO}")"
    assert_success
}

@test "representative git locations and wrappers block main mutations" {
    run_hook enforce_main_checkout_readonly "$(_payload Bash 'git commit' "${MAIN_REPO}")"
    assert_failure 2
    run_hook enforce_main_checkout_readonly "$(_payload Bash 'bash -c "git reset"' "${MAIN_REPO}")"
    assert_failure 2
    run_hook enforce_main_checkout_readonly "$(_payload Bash "eval 'git restore tracked.txt'" "${MAIN_REPO}")"
    assert_failure 2
    run_hook enforce_main_checkout_readonly "$(_payload Bash "git -C ${MAIN_REPO} rebase main" "${BATS_TEST_TMPDIR}")"
    assert_failure 2
    run_hook enforce_main_checkout_readonly "$(_payload Bash 'git commit' "${LINKED_REPO}")"
    assert_success
    run_hook enforce_main_checkout_readonly \
        "$(_payload Bash "cd ${LINKED_REPO} & git commit -m x" "${MAIN_REPO}")"
    assert_failure 2
    assert_output --partial "split the call or use git -C"
}

@test "representative allowed git and gh commands pass in main" {
    run_hook enforce_main_checkout_readonly "$(_payload Bash 'git pull --ff-only' "${MAIN_REPO}")"
    assert_success
    run_hook enforce_main_checkout_readonly "$(_payload Bash 'git worktree list' "${MAIN_REPO}")"
    assert_success
    run_hook enforce_main_checkout_readonly "$(_payload Bash 'git switch -q main' "${MAIN_REPO}")"
    assert_success
    run_hook enforce_main_checkout_readonly "$(_payload Bash 'gh issue view 276 --repo ycpss91255/worktool' "${MAIN_REPO}")"
    assert_success
}
