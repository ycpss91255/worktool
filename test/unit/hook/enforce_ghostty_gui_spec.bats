#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"
load "${BATS_TEST_DIRNAME}/../../helper/hook_state"

setup() {
    local project="${BATS_TEST_TMPDIR}/project"
    mkdir -p "${project}/.agents/hook"
    cp "${HOOK_DIR}/enforce_ghostty_gui.sh" "${project}/.agents/hook/"
    cp -R "${HOOK_DIR}/lib" "${project}/.agents/hook/"
    HOOK_DIR="${project}/.agents/hook"
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    printf '%s\n' '#!/usr/bin/env bash' \
        "printf '%s\\n' '1 0 Thu Oct 29 10:00:00 2026 init'" > "${BATS_TEST_TMPDIR}/bin/ps"
    chmod +x "${BATS_TEST_TMPDIR}/bin/ps"
    export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

_check() {
    local payload
    payload="$(hook_json "$1" | jq --arg id "${BATS_TEST_TMPDIR}" \
        '. + {hook_event_name:"PreToolUse",session_id:$id,tool_use_id:"call"}')"
    run_hook enforce_ghostty_gui "${payload}"
}

@test "Ghostty launches and actions are allowed for automatic cleanup" {
    local command
    for command in 'ghostty +new-window' 'ghostty +new-window --help' \
        'ghostty +new-window -h' 'ghostty' 'ghostty --help' \
        'ghostty +reload-config' 'ghostty +future-action --help' \
        'env DISPLAY=:0 ghostty +new-window' 'timeout 5s ghostty' \
        'bash -c "ghostty +new-window --help"' \
        "ghostty +list-\$action" 'ghostty +list-*'; do
        _check "${command}"
        assert_success
    done
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

@test "signals targeting Ghostty are blocked including PID lookup substitutions" {
    local command
    for command in 'pkill ghostty' 'pkill -HUP -x ghostty' \
        'pkill -f /usr/bin/ghostty' 'pkill -if Ghostty' \
        'killall ghostty' 'killall -s HUP /usr/bin/ghostty' \
        'kill -HUP ghostty' "kill -TERM \$(pgrep -x ghostty)" \
        "kill \$(pidof ghostty)" "kill -9 \`pgrep ghostty\`" \
        "kill -HUP \"\$ghostty_pid\"" "kill -s TERM \$(ps -C ghostty -o pid=)"; do
        _check "${command}"
        assert_failure 2
    done
}

@test "unrelated commands documentation text and script files remain allowed" {
    local command
    for command in 'printf "%s" "ghostty +new-window"' \
        'rg ghostty script/' 'command -v ghostty' 'kill -HUP 1234' \
        'pkill bash' 'killall sleep' "kill \$(pgrep bash)" \
        "printf \"%s\" ghostty; kill \"\$other_pid\"" \
        'bash script/verify/realbox.sh' 'just verify realbox --allow-real-box 5.2' \
        $'cat <<\'DOC\'\nghostty +new-window\npkill ghostty\nDOC'; do
        _check "${command}"
        assert_success
        assert_output ''
    done
}

@test "wrapped signals targeting Ghostty remain blocked" {
    local command
    for command in "builtin kill -HUP \$(pgrep ghostty)" \
        "eval 'pkill ghostty'" 'bash -c "killall ghostty"' \
        'env X=1 timeout 5 pkill ghostty'; do
        _check "${command}"
        assert_failure 2
    done
}

@test "unreadable command payloads fail closed while empty payloads remain allowed" {
    local payload
    for payload in '{' '{"tool_input":{"command":["ghostty","+new-window"]}}'; do
        run_hook enforce_ghostty_gui "${payload}"
        assert_failure 2
        assert_output --partial 'fail closed'
    done
    run_hook enforce_ghostty_gui '{}'
    assert_success
}
