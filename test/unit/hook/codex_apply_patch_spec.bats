#!/usr/bin/env bats
# test/unit/hook/codex_apply_patch_spec.bats - Codex apply_patch adapter.
#
# The adapter receives Codex's PreToolUse apply_patch JSON on stdin and
# delegates each affected file to the existing Claude Edit/Write hooks.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"make the change"}}' >"${TRANSCRIPT}"
}

_payload() {
    jq -n --arg tp "${TRANSCRIPT}" --arg command "$1" '{
        session_id:"s", turn_id:"t", transcript_path:$tp, cwd:"<dir>",
        hook_event_name:"PreToolUse", model:"m",
        permission_mode:"bypassPermissions", tool_name:"apply_patch",
        tool_input:{command:$command}, tool_use_id:"patch-1"
    }'
}

@test "an Add File introducing an unapproved ShellCheck disable is denied by the existing policy" {
    local _patch
    _patch="$(printf '*** Begin Patch\n*** Add File: script/new.sh\n+#!/usr/bin/env bash\n+%s\n*** End Patch' "$(disable_line SC1091)")"

    run_hook codex_apply_patch "$(_payload "${_patch}")"

    assert_success
    assert_output --partial 'SC1091'
    run jq -r '.hookSpecificOutput.permissionDecision' <<<"${output}"
    assert_output 'deny'
}

@test "an Update File introducing an unapproved ShellCheck disable is denied by the existing policy" {
    local _target _patch
    _target="${BATS_TEST_TMPDIR}/existing.sh"
    printf '#!/usr/bin/env bash\necho old\n' >"${_target}"
    _patch="$(printf '%s\n' \
        '*** Begin Patch' \
        "*** Update File: ${_target}" \
        '@@' \
        ' echo old' \
        "+$(disable_line SC2317)" \
        '*** End Patch')"

    run_hook codex_apply_patch "$(_payload "${_patch}")"

    assert_success
    assert_output --partial 'SC2317'
    run jq -r '.hookSpecificOutput.permissionDecision' <<<"${output}"
    assert_output 'deny'
}

@test "one patch delegates move, delete, and add as per-file Claude payloads" {
    local _repo _log _patch
    _repo="${BATS_TEST_TMPDIR}/adapter-repo"
    _log="${BATS_TEST_TMPDIR}/hook.log"
    mkdir -p "${_repo}/.agents/hook/lib" "${_repo}/.claude"
    cp "${HOOK_DIR}/codex_apply_patch.sh" "${_repo}/.agents/hook/"
    cp "${HOOK_DIR}/lib/hook_bootstrap.sh" "${_repo}/.agents/hook/lib/"
    cat >"${_repo}/.agents/hook/capture.sh" <<'HOOK'
#!/usr/bin/env bash
jq -c '{tool_name, tool_input}' >>"${CODEX_APPLY_PATCH_HOOK_LOG}"
HOOK
    chmod +x "${_repo}/.agents/hook/"*.sh
    cat >"${_repo}/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Edit|Write|MultiEdit","hooks":[{"type":"command","command":"${CLAUDE_PROJECT_DIR}/.claude/hook/capture.sh"}]}]}}
JSON
    _patch="$(printf '%s\n' \
        '*** Begin Patch' \
        '*** Update File: old.sh' \
        '*** Move to: moved.sh' \
        '@@' \
        '+echo moved' \
        '*** Delete File: gone.sh' \
        '*** Add File: fresh.sh' \
        '+echo fresh' \
        '*** End Patch')"

    run bash -c 'printf "%s" "$1" | CODEX_APPLY_PATCH_HOOK_LOG="$2" "$3"' _ \
        "$(_payload "${_patch}")" "${_log}" "${_repo}/.agents/hook/codex_apply_patch.sh"

    assert_success
    assert_output ''
    run jq -s -c '.' "${_log}"
    assert_output '[{"tool_name":"Edit","tool_input":{"file_path":"old.sh","new_string":""}},{"tool_name":"Write","tool_input":{"file_path":"moved.sh","content":"echo moved\n"}},{"tool_name":"Edit","tool_input":{"file_path":"gone.sh","new_string":""}},{"tool_name":"Write","tool_input":{"file_path":"fresh.sh","content":"echo fresh\n"}}]'
}
