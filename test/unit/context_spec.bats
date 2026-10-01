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

@test "CONTEXT.md defines user config separately from tool config" {
    run cat "${REPO_ROOT}/CONTEXT.md"
    assert_success
    assert_line '**user config**:'
    assert_output --partial '使用者自己的設定與憑證'
    run awk '/^\*\*user config\*\*:/ { on=1; next } on { print }' "${REPO_ROOT}/CONTEXT.md"
    assert_line '_Avoid_: dotfiles'
}

@test "agent domain guidance links the existing root glossary without a missing marker" {
    run cat "${REPO_ROOT}/AGENTS.md" "${REPO_ROOT}/doc/agent/domain.md"
    assert_success
    refute_output --regexp 'CONTEXT\.md[^；、\n]*尚未建立'
    assert_output --partial '[CONTEXT.md](CONTEXT.md)'
    assert_output --partial '[CONTEXT.md](../../CONTEXT.md)'
}
