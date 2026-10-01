#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"

@test "Claude rejects absent and foreign markers and accepts its own marker" {
    local _body _expected
    for _body in 'plain' '[codex] text' '[agy] text' '[gemini] text' '  [claude] text'; do
        _expected=2
        [[ "${_body}" == *'[claude]'* ]] && _expected=0
        run bash -c 'jq -n --arg c "gh issue comment 242 --repo ycpss91255/worktool --body '\''$1'\''" '\''{tool_name:"Bash",tool_input:{command:$c}}'\'' | "$2"' _ \
            "${_body}" "${REPO_ROOT}/.agents/hook/enforce_milestone_gate_approval.sh"
        assert_equal "${status}" "${_expected}"
    done
}
