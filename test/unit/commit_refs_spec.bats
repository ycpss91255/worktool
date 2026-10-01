#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR
# Commit issue footer policy (issue #312).
load ../helper/common

setup() {
    # shellcheck source=../../lib/commit_refs.sh
    source "${LIB_DIR}/commit_refs.sh"
    REPO="${BATS_TEST_TMPDIR}/repo"
    git init -q -b main "${REPO}"
    git -C "${REPO}" config user.name 'Test User'
    git -C "${REPO}" config user.email '12345+test@users.noreply.github.com'
}

_commit_refs() {
    printf '%s\n' "$1" > "${BATS_TEST_TMPDIR}/message"
    git -C "${REPO}" commit -q --allow-empty -F "${BATS_TEST_TMPDIR}/message"
}

@test "a commit without a Refs footer fails with its SHA" {
    _commit_refs 'missing footer'
    local _sha
    _sha="$(git -C "${REPO}" rev-parse HEAD)"
    run commit_refs_check_commits "${REPO}" HEAD
    assert_failure 1
    assert_output --partial "${_sha}"
    assert_output --partial 'Refs: #<number>'
}

@test "numeric Refs lines in the final paragraph pass, including multiple issues" {
    _commit_refs $'subject\n\nRefs: #312\nRefs: #42'
    run commit_refs_check_commits "${REPO}" HEAD
    assert_success
    assert_output --partial '1 commits checked: issue footers ok.'
}

@test "merge commits are exempt from the footer rule" {
    _commit_refs $'base\n\nRefs: #312'
    git -C "${REPO}" switch -q -c topic
    _commit_refs $'topic\n\nRefs: #312'
    git -C "${REPO}" switch -q main
    _commit_refs $'main\n\nRefs: #312'
    git -C "${REPO}" merge -q --no-ff topic -m 'Merge topic'
    run commit_refs_check_commits "${REPO}" HEAD
    assert_success
}

@test "GitHub web commits are exempt but normal noreply commits still need footers" {
    GIT_COMMITTER_NAME='GitHub' GIT_COMMITTER_EMAIL='noreply@github.com' _commit_refs 'web edit'
    run commit_refs_check_commits "${REPO}" HEAD
    assert_success
    GIT_COMMITTER_NAME='GitHub' GIT_COMMITTER_EMAIL='12345+test@users.noreply.github.com' _commit_refs 'local edit'
    run commit_refs_check_commits "${REPO}" HEAD
    assert_failure 1
}
