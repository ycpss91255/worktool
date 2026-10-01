#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"
bats_require_minimum_version 1.5.0
setup() {
    ROOT="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${ROOT}/script" "${ROOT}/.agents/script"
    git -C "${ROOT}" init -q
}
@test "rejects top-level executable scripts in both script trees" {
    local tree
    for tree in script .agents/script; do
        printf '#!/bin/sh\n' > "${ROOT}/${tree}/bad"
        chmod +x "${ROOT}/${tree}/bad"
    done
    run just -f "${REPO_ROOT}/justfile" test script-layout --root "${ROOT}"
    assert_failure 1
    assert_output --partial 'script/bad'
    assert_output --partial '.agents/script/bad'
}
@test "allows categorized scripts and ignores local state artifacts" {
    mkdir -p "${ROOT}/script/repo" "${ROOT}/.agents/script/monitor" "${ROOT}/.agents/state"
    touch "${ROOT}/script/repo/check" "${ROOT}/.agents/script/monitor/watch"
    chmod +x "${ROOT}/script/repo/check" "${ROOT}/.agents/script/monitor/watch"
    printf '.agents/state/\n' > "${ROOT}/.gitignore"
    touch "${ROOT}/.agents/state/local.log"
    run just -f "${REPO_ROOT}/justfile" test script-layout --root "${ROOT}"
    assert_success
    assert_output ''
}
@test "rejects every common artifact including tracked ignored files" {
    local path
    for path in note.bak note.orig note.rej note.log nested/_backup/keep nested/review_log/keep; do
        mkdir -p "${ROOT}/$(dirname "${path}")"
        touch "${ROOT}/${path}"
    done
    printf '*.log\n' > "${ROOT}/.gitignore"
    git -C "${ROOT}" add -f note.log
    run just -f "${REPO_ROOT}/justfile" test script-layout --root "${ROOT}"
    assert_failure 1
    for path in note.bak note.orig note.rej note.log nested/_backup/keep nested/review_log/keep; do
        assert_output --partial "${path}"
    done
}
@test "refuses a root that is not a Git repository" {
    rm -rf "${ROOT}/.git"
    run just -f "${REPO_ROOT}/justfile" test script-layout --root "${ROOT}"
    assert_failure 1
    assert_output --partial 'not a Git repository'
}
@test "lint rejects artifacts through the existing in-container gate" {
    mkdir -p "${ROOT}/script/test" "${ROOT}/lib" "${ROOT}/bin"
    cp "${REPO_ROOT}/script/test/test.sh" "${REPO_ROOT}/script/test/check-script-layout.sh" "${ROOT}/script/test/"
    cp "${REPO_ROOT}/lib/log.sh" "${ROOT}/lib/"
    printf '#!/bin/sh\nexit 0\n' > "${ROOT}/bin/shellcheck"
    chmod +x "${ROOT}/bin/shellcheck"
    touch "${ROOT}/failed.bak"
    run env PATH="${ROOT}/bin:${PATH}" bash "${ROOT}/script/test/test.sh" --ci-lint
    assert_failure 1
    assert_output --partial 'failed.bak'
}
