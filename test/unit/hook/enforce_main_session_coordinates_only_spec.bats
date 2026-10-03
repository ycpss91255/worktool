#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    local root="${BATS_TEST_TMPDIR}/workspace"
    mkdir -p "${root}/src" "${root}/worktree/x"
    git init -q "${root}/src"
    MAIN="${root}/src"
    WORK="${root}/worktree/x"
}

_check() {
    run_hook enforce_main_session_coordinates_only "$(jq -n \
        --arg c "$1" --arg cwd "${WORK}" --arg agent "${2:-}" \
        '{cwd:$cwd,agent_id:$agent,tool_name:"Bash",tool_input:{command:$c}}')"
}

_edit() {
    run_hook enforce_main_session_coordinates_only "$(jq -n \
        --arg p "$1" --arg cwd "${MAIN}" --arg agent "${2:-}" --arg tool "${3:-Write}" \
        '{cwd:$cwd,agent_id:$agent,tool_name:$tool,tool_input:{file_path:$p,notebook_path:$p}}')"
}

@test "main session cannot commit merge or push from a worktree" {
    local command
    for command in 'git commit -m fix' 'git merge origin/main' 'git push origin topic'; do
        _check "${command}"
        assert_equal "${status}" 2
        assert_output --partial 'pr-loop'
        assert_output --partial 'milestone-fanout'
        assert_output --partial 'milestone-handover'
    done
}
