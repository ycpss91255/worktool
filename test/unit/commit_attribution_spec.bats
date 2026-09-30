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
}
