#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

# Schema source: Claude Code hooks reference, checked 2026-10-02:
# https://code.claude.com/docs/en/hooks#common-input-fields
# Documentation-derived fixtures, not captured runtime input. Main calls
# omit agent_id; subagent tool calls add agent_id and agent_type.
_check() {
    run_hook enforce_codex_via_workflow "$(jq -n --arg c "$1" --arg cwd "${BATS_TEST_TMPDIR}" '
        {session_id:"abc123",transcript_path:"/missing/transcript.jsonl",
         cwd:$cwd,permission_mode:"default",hook_event_name:"PreToolUse",
         tool_name:"Bash",tool_input:{command:$c,description:"Run command",
         timeout:120000,run_in_background:false},tool_use_id:"toolu_01ABC123"}')"
}

@test "main loop implementation launches are refused with workflow guidance" {
    for cmd in 'codex exec "implement #366"' '/usr/bin/codex e "fix bug"' 'timeout 60 codex exec "implement"'; do
        _check "${cmd}"
        assert_equal "${status}" 2
        assert_output --partial 'pr-loop / milestone-fanout'
    done
}
