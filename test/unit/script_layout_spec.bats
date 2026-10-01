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
