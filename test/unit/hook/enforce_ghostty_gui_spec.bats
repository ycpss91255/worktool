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

@test "literal read-only Ghostty queries remain allowed" {
    local command
    for command in 'ghostty --version' 'ghostty +help' 'ghostty +version' \
        'ghostty +show-config' 'ghostty +show-config --default' \
        'ghostty +list-fonts' 'ghostty +list-themes' 'ghostty +list-keybinds' \
        'ghostty +list-actions' 'ghostty +list-colors'; do
        _check "${command}"
        assert_success
        assert_output ''
    done
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

@test "signals targeting Ghostty are blocked including PID lookup substitutions" {
    local command
    for command in 'pkill ghostty' 'pkill -HUP -x ghostty' \
        'pkill -f /usr/bin/ghostty' 'pkill -if Ghostty' \
        'killall ghostty' 'killall -s HUP /usr/bin/ghostty' \
        'kill -HUP ghostty' 'kill -TERM $(pgrep -x ghostty)' \
        'kill $(pidof ghostty)' 'kill -9 `pgrep ghostty`' \
        'kill -HUP "$ghostty_pid"' 'kill -s TERM $(ps -C ghostty -o pid=)'; do
        _check "${command}"
        assert_failure 2
    done
}

@test "read-only exemptions fail closed when arguments expand or add actions" {
    local command
    for command in 'ghostty +list-$action' 'ghostty +list-*' \
        'ghostty --version "$args"' 'ghostty +help $(printf +new-window)' \
        'ghostty +show-config +reload-config' 'ghostty +list-fonts +new-window'; do
        _check "${command}"
        assert_failure 2
    done
}
