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
