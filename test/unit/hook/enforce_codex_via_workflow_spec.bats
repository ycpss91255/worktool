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

@test "documented subagent identity allows implementation without reading transcripts" {
    local payload cmd
    for cmd in 'codex exec --sandbox workspace-write "implement"' 'bash missing.sh' "codex exec \"\$(cat prompt.txt)\""; do
        payload="$(jq -n --arg c "${cmd}" --arg cwd "${BATS_TEST_TMPDIR}" '
            {session_id:"abc123",transcript_path:"/missing/transcript.jsonl",
             cwd:$cwd,permission_mode:"default",hook_event_name:"PreToolUse",
             tool_name:"Bash",tool_input:{command:$c},tool_use_id:"toolu_01ABC123",
             agent_id:"agent-abc123",agent_type:"general-purpose"}')"
        run_hook enforce_codex_via_workflow "${payload}"
        assert_success
    done
    for identity in 'null' '""' 'false' '123' '[]' '{}'; do
        payload="$(jq -n --argjson a "${identity}" '
            {agent_id:$a,tool_name:"Bash",tool_input:{command:"codex exec implement"}}')"
        run_hook enforce_codex_via_workflow "${payload}"
        assert_equal "${status}" 2
    done
    _check 'codex exec "implement"'
    assert_equal "${status}" 2
}

@test "main loop read-only sandbox queries pass without subagent identity" {
    for cmd in 'codex exec --sandbox read-only "research"' 'codex e -s read-only "discuss"' 'codex exec --sandbox=read-only -o answer.md "verify"'; do
        _check "${cmd}"
        assert_success
    done
    _check 'git status --short'
    assert_success
}
