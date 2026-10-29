#!/usr/bin/env bash
# Compare file lists so existing agent state is preserved and allowed.
hook_state_files() {
    if [[ -d "${REPO_ROOT}/.agents/state" ]]; then
        find "${REPO_ROOT}/.agents/state" -type f -print0 | sort -z
    fi
}

setup_file() {
    hook_state_files > "${BATS_FILE_TMPDIR}/state-before"
}

teardown_file() {
    hook_state_files > "${BATS_FILE_TMPDIR}/state-after"
    comm -z -13 "${BATS_FILE_TMPDIR}/state-before" "${BATS_FILE_TMPDIR}/state-after" \
        > "${BATS_FILE_TMPDIR}/state-added"
    run tr '\0' '\n' < "${BATS_FILE_TMPDIR}/state-added"
    assert_success
    assert_output ''
}
