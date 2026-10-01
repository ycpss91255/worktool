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

@test "Codex registration rejects foreign markers and accepts its own marker" {
    local _body _expected _command _repo
    _repo="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${_repo}/test/unit"
    cp -R "${REPO_ROOT}/.agents" "${_repo}/.agents"
    cp -R "${REPO_ROOT}/lib" "${_repo}/lib"
    git init -q "${_repo}"
    _command="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(contains("enforce_milestone_gate_approval"))' "${REPO_ROOT}/.codex/hooks.json")"
    for _body in plain '[claude] text' '[agy] text' '[gemini] text' '  [codex] text'; do
        _expected=2
        [[ "${_body}" == *'[codex]'* ]] && _expected=0
        run bash -c 'cd "$3" && jq -n --arg c "gh issue comment 242 --repo ycpss91255/worktool --body '\''$1'\''" '\''{tool_name:"Bash",tool_input:{command:$c}}'\'' | bash -c "$2"' _ \
            "${_body}" "${_command}" "${_repo}/test/unit"
        assert_equal "${status}" "${_expected}"
    done
}

@test "agy adapter rejects absent and foreign markers and accepts its own marker" {
    local _body _expected
    for _body in plain '[claude] text' '[codex] text' '[gemini] text' '  [agy] text'; do
        _expected=2
        [[ "${_body}" == *'[agy]'* ]] && _expected=0
        run bash -c 'jq -n --arg c "gh issue comment 242 --repo ycpss91255/worktool --body '\''$1'\''" '\''{tool_name:"run_command",tool_input:{CommandLine:$c}}'\'' | "$2"' _ \
            "${_body}" "${REPO_ROOT}/.agents/hook/agy_comment.sh"
        assert_equal "${status}" "${_expected}"
    done
}

@test "Gemini adapter rejects absent and foreign markers and accepts its own marker" {
    local _body _expected
    for _body in plain '[claude] text' '[codex] text' '[agy] text' '  [gemini] text'; do
        _expected=2
        [[ "${_body}" == *'[gemini]'* ]] && _expected=0
        run bash -c 'jq -n --arg c "gh issue comment 242 --repo ycpss91255/worktool --body '\''$1'\''" '\''{hook_event_name:"BeforeTool",tool_name:"run_shell_command",tool_input:{command:$c}}'\'' | "$2"' _ \
            "${_body}" "${REPO_ROOT}/.agents/hook/gemini_comment.sh"
        assert_equal "${status}" "${_expected}"
    done
}
