#!/usr/bin/env bats
# Root glossary guards for the settled vocabulary of issue #212.
load "${BATS_TEST_DIRNAME}/../helper/common"

@test "CONTEXT.md defines tool config with its avoided ambiguous synonym" {
    run cat "${REPO_ROOT}/CONTEXT.md"
    assert_success
    assert_line '**tool config**:'
    assert_output --partial '盒內工具的設定'
    assert_line '_Avoid_: dotfiles'
}
