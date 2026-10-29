#!/usr/bin/env bash
# test/helper/hook_state.bash - worktree state leak guard for hook specs.
#
# Load after common.bash, then explicitly call from the spec's lifecycle:
#   load "${BATS_TEST_DIRNAME}/../../helper/hook_state"
#   setup_file() {
#       hook_state_guard_begin
#   }
#   teardown_file() {
#       hook_state_guard_end
#   }
#
# Provides:
#   hook_state_guard_begin  snapshot existing worktree state files
#   hook_state_guard_end    fail if any new worktree state files remain
#
# Existing files are allowed. Concurrent writers to the same worktree state
# can also fail this guard locally; CI has no such concurrent agent writers.

# Compare file lists so existing agent state is preserved and allowed.
hook_state_files() {
    if [[ -d "${REPO_ROOT}/.agents/state" ]]; then
        find "${REPO_ROOT}/.agents/state" -type f -print0 | sort -z
    fi
}

hook_state_guard_begin() {
    hook_state_files > "${BATS_FILE_TMPDIR}/state-before"
}

hook_state_guard_end() {
    hook_state_files > "${BATS_FILE_TMPDIR}/state-after"
    comm -z -13 "${BATS_FILE_TMPDIR}/state-before" "${BATS_FILE_TMPDIR}/state-after" \
        > "${BATS_FILE_TMPDIR}/state-added"
    run tr '\0' '\n' < "${BATS_FILE_TMPDIR}/state-added"
    assert_success
    assert_output ''
}
