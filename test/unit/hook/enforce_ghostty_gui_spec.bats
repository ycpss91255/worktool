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

@test "GUI launches and actions outside the read-only allowlist are blocked" {
    local command
    for command in 'ghostty' 'ghostty --help' 'ghostty -h' \
        'ghostty --working-directory=/tmp' 'ghostty +new-tab' \
        'ghostty +reload-config' 'ghostty +quit' 'ghostty +future-action --help' \
        'ghostty --version +new-window' 'ghostty +help +new-window'; do
        _check "${command}"
        assert_failure 2
    done
}
