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

_introduce_refs_rule() {
    mkdir -p "${REPO}/lib"
    cp "${LIB_DIR}/commit_refs.sh" "${REPO}/lib/commit_refs.sh"
    git -C "${REPO}" add lib/commit_refs.sh
    _commit_refs $'Introduce footer check\n\nRefs: #312'
}

@test "pre-rule commits without footers are skipped by ancestry" {
    _commit_refs 'old work without footer'
    local _old
    _old="$(git -C "${REPO}" rev-parse HEAD)"
    _introduce_refs_rule
    git -C "${REPO}" switch -q -c old-topic "${_old}"
    _commit_refs 'work on a branch that never adopted the rule'
    local _topic
    _topic="$(git -C "${REPO}" rev-parse HEAD)"
    git -C "${REPO}" switch -q main
    run commit_refs_check_commits "${REPO}" "${_old}" "${_topic}"
    assert_success
    assert_output --partial "${_old} skipped: does not descend from enforcing commit"
    assert_output --partial "${_topic} skipped: does not descend from enforcing commit"
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

@test "PR and push ranges exclude old commits and validate event inputs" {
    _commit_refs 'old commit without footer'
    local _base _head _range
    _base="$(git -C "${REPO}" rev-parse HEAD)"
    git -C "${REPO}" update-ref refs/remotes/origin/main "${_base}"
    _commit_refs $'new work\n\nRefs: #312'
    _head="$(git -C "${REPO}" rev-parse HEAD)"
    local _event
    for _event in pull_request push; do
        _range="$(commit_refs_range "${_event}" "${_base}" "${_head}" "${_base}" "${_head}" refs/remotes/origin/main)"
        run commit_refs_check_commits "${REPO}" "${_range}"
        assert_success
        assert_output --partial '1 commits checked'
    done
    _range="$(commit_refs_range push ignored ignored 0000000000000000000000000000000000000000 "${_head}" refs/remotes/origin/main)"
    local -a _revs
    mapfile -t _revs <<< "${_range}"
    run commit_refs_check_commits "${REPO}" "${_revs[@]}"
    assert_success
    assert_output --partial '1 commits checked'
    run commit_refs_range push ignored ignored '' "${_head}" refs/remotes/origin/main
    assert_failure 1
    assert_output --partial 'fail closed'
}
