#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

_check() { run_hook enforce_ghostty_gui "$(hook_json "$1")"; }

@test "new-window is blocked with any arguments including help" {
    local command
    for command in 'ghostty +new-window' 'ghostty +new-window --help' \
        'ghostty +new-window -h' 'ghostty +new-window --working-directory=/tmp'; do
        _check "${command}"
        assert_failure 2
        assert_output --partial '[hook:enforce-ghostty-gui] BLOCKED'
        assert_output --partial 'Docker'
    done
    run jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] |
        select(.command == "${CLAUDE_PROJECT_DIR}/.claude/hook/enforce_ghostty_gui.sh")' \
        "${REPO_ROOT}/.claude/settings.json"
    assert_success
}
