#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    local project="${BATS_TEST_TMPDIR}/project"
    mkdir -p "${project}/.agents/hook" "${BATS_TEST_TMPDIR}/bin"
    cp "${HOOK_DIR}/enforce_ghostty_gui.sh" "${project}/.agents/hook/"
    cp -R "${HOOK_DIR}/lib" "${project}/.agents/hook/"
    HOOK_DIR="${project}/.agents/hook"
    export PS_FIXTURE="${BATS_TEST_TMPDIR}/processes" SIGNAL_LOG="${BATS_TEST_TMPDIR}/signals"
    export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
    cat > "${BATS_TEST_TMPDIR}/bin/ps" <<'STUB'
#!/usr/bin/env bash
[[ "${PS_FAIL:-0}" == 0 ]] || exit 1
cat "${PS_FIXTURE}"
STUB
    cat > "${BATS_TEST_TMPDIR}/bin/kill" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SIGNAL_LOG}"
STUB
    chmod +x "${BATS_TEST_TMPDIR}/bin/ps" "${BATS_TEST_TMPDIR}/bin/kill"
    : > "${SIGNAL_LOG}"
    printf '%s\n' '100 1 Thu Oct 29 10:00:00 2026 ghostty' \
        '101 100 Thu Oct 29 10:00:01 2026 bash' > "${PS_FIXTURE}"
}

_event() {
    local payload
    payload="$(jq -n --arg e "$1" --arg id "${2:-call-1}" \
        '{hook_event_name:$e,session_id:"session-1",tool_use_id:$id,
        tool_name:"Bash",tool_input:{command:"ghostty +new-window --help"}}')"
    run_hook enforce_ghostty_gui "${payload}"
}

@test "new window shells across all Ghostty processes are closed and reported" {
    _event PreToolUse
    assert_success
    printf '%s\n' '102 100 Thu Oct 29 10:01:00 2026 fish' \
        '200 1 Thu Oct 29 10:01:00 2026 ghostty' \
        '201 200 Thu Oct 29 10:01:01 2026 zsh' >> "${PS_FIXTURE}"
    _event PostToolUse
    assert_success
    assert_output --partial '102'
    assert_output --partial '201'
    run cat "${SIGNAL_LOG}"
    assert_output $'-HUP -- 102\n-HUP -- 201'
}

@test "failed Bash commands close new window shells and consume their snapshot" {
    _event PreToolUse
    assert_success
    printf '%s\n' '102 100 Thu Oct 29 10:01:00 2026 fish' >> "${PS_FIXTURE}"
    _event PostToolUseFailure
    assert_success
    run jq -r '.hookSpecificOutput.hookEventName' <<<"${output}"
    assert_output 'PostToolUseFailure'
    run cat "${SIGNAL_LOG}"
    assert_output '-HUP -- 102'
    run find "${HOOK_DIR}/../state/ghostty-windows" -name '*.json'
    assert_output ''
}

@test "malformed process lists are reported instead of erasing pre-existing windows" {
    local event mode
    for event in PreToolUse PostToolUse; do
        for mode in malformed empty failed; do
            export PS_FAIL=0
            printf '%s\n' '100 1 Thu Oct 29 10:00:00 2026 ghostty' > "${PS_FIXTURE}"
            if [[ "${event}" == PostToolUse ]]; then
                _event PreToolUse
                assert_success
            fi
            case "${mode}" in
                malformed) printf '%s\n' 'unreadable process row' > "${PS_FIXTURE}" ;;
                empty) : > "${PS_FIXTURE}" ;;
                failed) export PS_FAIL=1 ;;
            esac
            _event "${event}"
            assert_failure 2
            assert_output --partial 'Ghostty window cleanup failed'
        done
    done
    run cat "${SIGNAL_LOG}"
    assert_output ''
}

@test "corrupt comparison snapshots never turn pre-existing windows into cleanup targets" {
    _event PreToolUse
    assert_success
    local snapshot
    snapshot="$(find "${HOOK_DIR}/../state/ghostty-windows" -name '*.json')"
    printf '%s\n' '{"command":"ghostty +new-window --help","windows":[{}]}' > "${snapshot}"
    _event PostToolUse
    assert_failure 2
    assert_output --partial 'cannot compare window snapshots'
    run cat "${SIGNAL_LOG}"
    assert_output ''
}

@test "both agents register window cleanup after Bash commands" {
    local config
    for config in .claude/settings.json .codex/hooks.json; do
        run jq -e '.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[] |
            select(.command | contains("/enforce_ghostty_gui.sh"))' "${REPO_ROOT}/${config}"
        assert_success
    done
}

@test "cleanup revalidates shell identity before signaling a reused PID" {
    _event PreToolUse
    assert_success
    printf '%s\n' '102 100 Thu Oct 29 10:01:00 2026 fish' >> "${PS_FIXTURE}"
    cp "${PS_FIXTURE}" "${PS_FIXTURE}.next"
    sed -i 's/102 100 Thu Oct 29 10:01:00 2026 fish/102 1 Thu Oct 29 10:02:00 2026 unrelated/' "${PS_FIXTURE}.next"
    cat > "${BATS_TEST_TMPDIR}/bin/ps" <<'STUB'
#!/usr/bin/env bash
cat "${PS_FIXTURE}"
cp "${PS_FIXTURE}.next" "${PS_FIXTURE}"
STUB
    _event PostToolUse
    assert_failure 2
    assert_output --partial 'identity changed'
    run cat "${SIGNAL_LOG}"
    assert_output ''
}

@test "window cleanup uses hangup for interactive shells that can ignore TERM" {
    _event PreToolUse
    assert_success
    printf '%s\n' '102 100 Thu Oct 29 10:01:00 2026 bash' >> "${PS_FIXTURE}"
    _event PostToolUse
    assert_success
    run cat "${SIGNAL_LOG}"
    assert_output '-HUP -- 102'
}

@test "missing invocation identity fails closed before recording a window baseline" {
    run_hook enforce_ghostty_gui "$(hook_json 'ghostty +new-window')"
    assert_failure 2
    assert_output --partial 'cannot identify the Bash invocation'
}

@test "numeric signals aimed at host Ghostty PIDs are denied" {
    local command payload
    for command in 'kill -HUP 100' '/bin/kill -9 100' 'builtin kill -s TERM 100'; do
        payload="$(hook_json "${command}" | jq \
            '. + {hook_event_name:"PreToolUse",session_id:"s",tool_use_id:"call"}')"
        run_hook enforce_ghostty_gui "${payload}"
        assert_failure 2
        assert_output --partial 'Do not signal host Ghostty'
    done
}

@test "cleanup never signals a Ghostty process nested under another Ghostty process" {
    _event PreToolUse
    assert_success
    printf '%s\n' '200 100 Thu Oct 29 10:01:00 2026 Ghostty' \
        '201 200 Thu Oct 29 10:01:01 2026 zsh' >> "${PS_FIXTURE}"
    _event PostToolUse
    assert_success
    run cat "${SIGNAL_LOG}"
    assert_output '-HUP -- 201'
}
