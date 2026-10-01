#!/usr/bin/env bats
# test/unit/hook/worktree_create_spec.bats - .agents/hook/worktree_create.sh
#
# The WorktreeCreate hook places Claude Code's worktrees at
# <repo>/../worktree/<name> (the same place the pr-loop workflow
# uses) and prints ONLY that absolute path on stdout. Driven as a subprocess
# with a throwaway git repo as CLAUDE_PROJECT_DIR.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    FAKE_REPO="${BATS_TEST_TMPDIR}/repo"
    git init -q "${FAKE_REPO}"
    git -C "${FAKE_REPO}" config user.email t@e.st
    git -C "${FAKE_REPO}" config user.name tester
    git -C "${FAKE_REPO}" commit -q --allow-empty -m init
}

# _create <payload> - git chatter (stderr) is dropped so ${output} is the
# clean stdout Claude Code reads.
_create() {
    run bash -c 'printf "%s" "$1" | CLAUDE_PROJECT_DIR="$2" "$3" 2>/dev/null' _ \
        "$1" "${FAKE_REPO}" "${HOOK_DIR}/worktree_create.sh"
}

_named() { _create "$(jq -n --arg n "$1" '{name:$n}')"; }

@test "creates the worktree under <repo>/../worktree/<name> and prints only the path" {
    _named "agent-abc"
    assert_success
    assert_output "${BATS_TEST_TMPDIR}/worktree/agent-abc"
    [ -e "${BATS_TEST_TMPDIR}/worktree/agent-abc/.git" ]
}

@test "creates the worktree on a worktree-<name> branch" {
    _named "agent-xyz"
    assert_success
    run git -C "${FAKE_REPO}" worktree list
    assert_output --partial "[worktree-agent-xyz]"
}

@test "is idempotent: re-running returns the same path" {
    _named "dup"
    assert_success
    _named "dup"
    assert_success
    assert_output "${BATS_TEST_TMPDIR}/worktree/dup"
}

@test "rejects a name with a path separator" {
    _named "../evil"
    assert_failure
    [ ! -e "${FAKE_REPO}/evil" ]
}

@test "rejects a name containing .." {
    _named "a..b"
    assert_failure
}

@test "rejects '.' (it would hand back the worktree root itself)" {
    _named "."
    assert_failure
    assert_output ""
}

@test "rejects a name that git could read as an option" {
    _named "-b"
    assert_failure
    assert_output ""
}

@test "does not hand back a plain directory that is not a worktree" {
    mkdir -p "${BATS_TEST_TMPDIR}/worktree/plain"
    _named "plain"
    assert_failure
    assert_output ""
}

@test "fails when .name is missing from the payload" {
    _create "{}"
    assert_failure
}

@test "a misrouted tool-use payload is a no-op (exit 0, nothing created)" {
    _create "$(hook_json "ls")"
    assert_success
    assert_output ""
    [ ! -e "${BATS_TEST_TMPDIR}/worktree" ]
}
