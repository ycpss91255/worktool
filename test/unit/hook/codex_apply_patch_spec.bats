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
