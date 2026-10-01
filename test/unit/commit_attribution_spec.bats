#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR
# test/unit/commit_attribution_spec.bats - commit and PR attribution checks
# (issue #271)

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

setup() {
    # shellcheck source=../../lib/commit_attribution.sh
    source "${LIB_DIR}/commit_attribution.sh"
    REPO="${BATS_TEST_TMPDIR}/repo"
    git init -q "${REPO}"
    git -C "${REPO}" config user.name 'Test User'
    git -C "${REPO}" config user.email '12345+test@users.noreply.github.com'
}

_commit() {
    local _message_file="${BATS_TEST_TMPDIR}/message"
    printf '%s\n' "$2" > "${_message_file}"
    git -C "$1" commit -q --allow-empty -F "${_message_file}"
}

_check_range() {
    run commit_attribution_check_commits "${REPO}" "$1"
}

@test "commit_attribution.sh can be sourced without output or shell option changes" {
    run bash -c 'before="$(set -o; shopt)"; source "$1"; after="$(set -o; shopt)"; [[ "${before}" == "${after}" ]]' \
        _ "${LIB_DIR}/commit_attribution.sh"
    assert_success
    assert_output ''
}

@test "an attribution line in a commit fails with its sha and line" {
    _commit "${REPO}" 'base'
    local _base _bad_line _bad
    _base="$(git -C "${REPO}" rev-parse HEAD)"
    _bad_line='Co-Authored-By: Claude <noreply@anthropic.com>'
    _commit "${REPO}" $'subject\n\n'"${_bad_line}"
    _bad="$(git -C "${REPO}" rev-parse HEAD)"

    _check_range "${_base}..${_bad}"

    assert_failure 1
    assert_output --partial "${_bad}"
    assert_output --partial "${_bad_line}"
    assert_line --regexp "^\\[ERROR\\] ${_bad} ${_bad_line}$"
}

@test "an attribution line in a pull request body fails with the line and fix" {
    local _bad_line='Claude-Session: fixture-session'

    run commit_attribution_check_pr_body pull_request $'Summary\n'"${_bad_line}"

    assert_failure 1
    assert_output --partial "${_bad_line}"
    assert_output --partial 'edit the PR body'
}

@test "all three attribution forms fail while clean and normal Claude prose pass" {
    _commit "${REPO}" 'base'
    local _base _line
    _base="$(git -C "${REPO}" rev-parse HEAD)"
    for _line in \
        'Co-Authored-By: Claude <noreply@anthropic.com>' \
        'Claude-Session: fixture-session' \
        'Generated with Claude Code'; do
        _commit "${REPO}" $'subject\n\n'"${_line}"
    done
    _check_range "${_base}..HEAD"
    assert_failure 1
    for _line in 'Co-Authored-By:' 'Claude-Session:' 'Generated with Claude Code'; do
        assert_output --partial "${_line}"
    done

    git -C "${REPO}" reset -q --hard "${_base}"
    _commit "${REPO}" 'Document how Claude is mentioned in normal prose'
    _commit "${REPO}" 'A clean message'
    _check_range "${_base}..HEAD"
    assert_success
}

@test "an attribution line in a merge commit is detected" {
    _commit "${REPO}" 'base'
    local _base _bad
    _base="$(git -C "${REPO}" rev-parse HEAD)"
    git -C "${REPO}" switch -q -c topic
    _commit "${REPO}" 'topic work'
    git -C "${REPO}" switch -q master
    _commit "${REPO}" 'main work'
    local _message_file="${BATS_TEST_TMPDIR}/merge-message"
    printf '%s\n' $'Merge topic\n\nGenerated with Claude Code' > "${_message_file}"
    git -C "${REPO}" merge -q --no-ff topic -F "${_message_file}"
    _bad="$(git -C "${REPO}" rev-parse HEAD)"

    _check_range "${_base}..HEAD"

    assert_failure 1
    assert_output --partial "${_bad}"
}

@test "an old attribution commit outside the range is ignored" {
    _commit "${REPO}" $'old\n\nClaude-Session: old-fixture'
    _commit "${REPO}" 'range base'
    local _base
    _base="$(git -C "${REPO}" rev-parse HEAD)"
    _commit "${REPO}" 'new clean work'

    _check_range "${_base}..HEAD"

    assert_success
}

@test "push ignores a pull request body" {
    run commit_attribution_check_pr_body push $'Summary\nClaude-Session: fixture-session'
    assert_success
}

@test "range mirrors commit-email for pull requests and pushes" {
    local _a='1111111111111111111111111111111111111111'
    local _b='2222222222222222222222222222222222222222'
    local _zero='0000000000000000000000000000000000000000'
    local _default='refs/remotes/origin/main'

    run commit_attribution_range pull_request "${_a}" "${_b}" ignored ignored "${_default}"
    assert_success
    assert_output "${_a}..${_b}"
    run commit_attribution_range push ignored ignored "${_a}" "${_b}" "${_default}"
    assert_success
    assert_output "${_a}..${_b}"
    run commit_attribution_range push ignored ignored "${_zero}" "${_b}" "${_default}"
    assert_success
    assert_line "${_b}"
    assert_line "^${_default}"
}
