#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

_check() {
    run_hook enforce_codex_via_workflow "$(jq -n --arg c "$1" --arg cwd "${BATS_TEST_TMPDIR}" --arg t "${TRANSCRIPT:-}" \
        '{tool_name:"Bash",cwd:$cwd,transcript_path:$t,tool_input:{command:$c}}')"
}

@test "main loop implementation launches are refused with workflow guidance" {
    for cmd in 'codex exec "implement #366"' '/usr/bin/codex e "fix bug"' 'timeout 60 codex exec "implement"'; do
        _check "${cmd}"
        assert_equal "${status}" 2
        assert_output --partial 'pr-loop / milestone-fanout'
    done
}
