#!/usr/bin/env bats
# test/unit/hook/check_main_fresh_before_worktree_spec.bats
#   - .agents/hook/check_main_fresh_before_worktree.sh
#
# DENIES (permissionDecision "deny", exit 0) a `git worktree add ... main` or
# `... origin/main` while local main is behind origin/main, so a new
# worktree never starts from a stale base. Allows when up to date, when not
# branching from main, and outside a git repo. Driven against a throwaway
# origin / clone pair so the hook's real `git fetch` runs.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

_identity() {
    git -C "$1" config user.email t@e.st
    git -C "$1" config user.name tester
}

setup() {
    SEED="${BATS_TEST_TMPDIR}/seed"
    ORIGIN="${BATS_TEST_TMPDIR}/origin.git"
    CLONE="${BATS_TEST_TMPDIR}/clone"
    git init -q -b main "${SEED}"
    _identity "${SEED}"
    git -C "${SEED}" commit -q --allow-empty -m init
    git clone -q --bare "${SEED}" "${ORIGIN}"
    git clone -q "${ORIGIN}" "${CLONE}"
    _identity "${CLONE}"
}

_check() { run_hook check_main_fresh_before_worktree "$(hook_json "$1")"; }

# Push one more commit to origin/main from a second clone, so CLONE falls
# behind once the hook fetches.
_advance_origin() {
    local _pusher="${BATS_TEST_TMPDIR}/pusher"
    git clone -q "${ORIGIN}" "${_pusher}"
    _identity "${_pusher}"
    git -C "${_pusher}" commit -q --allow-empty -m advance
    git -C "${_pusher}" push -q origin main
}

@test "denies worktree-from-main when local main is behind origin/main" {
    _advance_origin
    _check "git -C ${CLONE} worktree add ${BATS_TEST_TMPDIR}/wt main"
    assert_success
    run jq -r '.hookSpecificOutput.permissionDecision' <<<"${output}"
    assert_output "deny"
}

@test "the deny reason names the lag and the ff-only pull to run" {
    _advance_origin
    _check "git -C ${CLONE} worktree add ${BATS_TEST_TMPDIR}/wt origin/main"
    assert_success
    assert_output --partial "1 commit(s) behind origin/main"
    assert_output --partial "pull --ff-only origin main"
}

@test "allows worktree-from-main when local main is up to date" {
    _check "git -C ${CLONE} worktree add ${BATS_TEST_TMPDIR}/wt main"
    assert_success
    assert_output ""
}

@test "allows a worktree that does not branch from main" {
    _advance_origin
    _check "git -C ${CLONE} worktree add ${BATS_TEST_TMPDIR}/wt -b feat/x"
    assert_success
    assert_output ""
}

@test "allows when the working dir is not a git repo" {
    mkdir -p "${BATS_TEST_TMPDIR}/notrepo"
    _check "git -C ${BATS_TEST_TMPDIR}/notrepo worktree add ${BATS_TEST_TMPDIR}/wt main"
    assert_success
    assert_output ""
}

@test "allows a non-worktree command" {
    _check "git -C ${CLONE} status"
    assert_success
    assert_output ""
}
