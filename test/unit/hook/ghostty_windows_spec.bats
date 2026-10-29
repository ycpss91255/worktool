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
    assert_output $'-TERM -- 102\n-TERM -- 201'
}
