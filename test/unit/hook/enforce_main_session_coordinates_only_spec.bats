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

@test "main session cannot run other git mutations or hide them behind options" {
    local command
    for command in 'git rebase main' 'git cherry-pick HEAD' 'git revert HEAD' \
        'git am patch' 'git reset --hard' 'git checkout -- file' 'git restore file' \
        'git stash list' 'git apply patch' 'git -C /tmp commit -m fix' \
        'git --git-dir=/tmp/repo merge main' 'git -c user.name=agent push' \
        'git pull' 'git pull --ff-only --no-ff'; do
        _check "${command}"
        assert_equal "${status}" 2
    done
}

@test "main session delegates just tests and Docker bats execution" {
    local command
    for command in 'just test unit' 'just test lint' 'just --justfile justfile test guards' \
        'just -d /tmp test unit' 'timeout 60 just test unit' \
        'docker run --rm image bats test/unit/x.bats' \
        'docker exec box /usr/bin/bats test/unit/x.bats' \
        "docker run image bash -c 'bats test/unit/x.bats'"; do
        _check "${command}"
        assert_equal "${status}" 2
    done
}
