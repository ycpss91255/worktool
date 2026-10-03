#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    local root="${BATS_TEST_TMPDIR}/workspace"
    mkdir -p "${root}/src" "${root}/worktree/x"
    git init -q "${root}/src"
    MAIN="${root}/src"
    WORK="${root}/worktree/x"
    mkdir -p "${MAIN}/.agents/hook"
    cp "${HOOK_DIR}/enforce_main_session_coordinates_only.sh" "${MAIN}/.agents/hook/"
    cp -R "${HOOK_DIR}/lib" "${MAIN}/.agents/hook/"
    HOOK_DIR="${MAIN}/.agents/hook"
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

@test "main session file tools cannot edit the sibling worktree directory" {
    local tool path
    for tool in Write Edit MultiEdit NotebookEdit; do
        for path in "${WORK}/file" '../worktree/x/file' '../worktree/new/file'; do
            _edit "${path}" '' "${tool}"
            assert_equal "${status}" 2
        done
    done
    # The current checkout can itself be a linked worktree.
    git -C "${MAIN}" -c user.name=Test -c user.email=test@users.noreply.github.com \
        commit -q --allow-empty -m fixture
    git -C "${MAIN}" worktree add -q "${WORK}" -b fixture
    MAIN="${WORK}"
    _edit 'file'
    assert_equal "${status}" 2
}

@test "nonempty subagent identity allows git tests and file edits" {
    local command
    for command in 'git commit -m fix' 'git merge main' 'git push' 'just test unit' \
        'docker run image bats spec.bats'; do
        _check "${command}" 'agent-workflow'
        assert_success
    done
    _edit "${WORK}/file" 'agent-workflow'
    assert_success
    _edit "${WORK}/notebook" 'agent-workflow' NotebookEdit
    assert_success
    local identity
    for identity in 'null' '""' 'false' '123' '[]' '{}'; do
        run_hook enforce_main_session_coordinates_only "$(jq -n --argjson a "${identity}" \
            '{agent_id:$a,tool_name:"Bash",tool_input:{command:"git commit -m fix"}}')"
        assert_equal "${status}" 2
    done
}

@test "main session retains coordination reads synchronization and memory writes" {
    local command path
    for command in 'gh pr merge 1 --repo ycpss91255/worktool' \
        'gh pr comment 1 --repo ycpss91255/worktool --body-file /tmp/body' \
        'gh pr review 1 --repo ycpss91255/worktool --approve' \
        'gh issue view 416 --repo ycpss91255/worktool' \
        'git fetch' 'git log' 'git status --short' 'git diff' 'git -C /tmp log' \
        'git pull --ff-only' 'git worktree add ../worktree/new' \
        'git worktree remove ../worktree/old' 'git worktree prune' 'git worktree list' \
        'docker ps' 'just box status'; do
        _check "${command}"
        assert_success
    done
    for path in '.agents/memory/note.md' "${WORK}/.agents/memory/note.md" \
        "${BATS_TEST_TMPDIR}/body.md" '../worktree-other/body.md'; do
        _edit "${path}"
        assert_success
    done
}

@test "indirect shell execution fails closed when it mentions restricted actions" {
    local command
    for command in "bash -c 'git commit -m fix'" 'eval git push' \
        'printf x | xargs git commit' "bash -c \"\$CMD\" # git commit" \
        "eval \"\$CMD\" # just test unit" 'xargs just test unit' \
        $'sh <<\'SCRIPT\'\ngit merge main\nSCRIPT' \
        $'bash <<SCRIPT\njust test unit\nSCRIPT' \
        "sh <<< 'git push'" \
        "python3 -c 'import os; os.system(\"git commit -m fix\")'"; do
        _check "${command}"
        assert_equal "${status}" 2
    done
    for command in "bash -c 'git log'" 'printf x | xargs echo' "eval 'echo ready'" \
        $'cat <<EOF\ngit commit -m example\njust test unit\nEOF'; do
        _check "${command}"
        assert_success
    done
}

@test "quoted and expanded restricted launches cannot bypass the closed rule" {
    local command
    for command in "xargs 'git' 'commit'" "xargs -n 1 git -C '/tmp' 'push'" \
        "xargs 'just' 'test' unit" "git -C \"\$DIR\" commit -m fix" \
        'git -C/tmp commit -m fix'; do
        _check "${command}"
        assert_equal "${status}" 2
    done
    # Use valid JSON with agent_id omitted, as supplied for a main session.
    run_hook enforce_main_session_coordinates_only \
        '{"tool_name":"Bash","tool_input":{"command":"git commit -m fix"}}'
    assert_equal "${status}" 2
}

@test "main session limits worktree management to the approved operations" {
    local command
    for command in 'git worktree move old new' 'git worktree repair' \
        'git worktree lock old' 'git worktree unlock old'; do
        _check "${command}"
        assert_equal "${status}" 2
    done
}

@test "main session permits read-only git root flags" {
    local command
    for command in 'git --version' 'git --help' 'git -h' 'git -P log' 'git --bare log'; do
        _check "${command}"
        assert_success
    done
}

@test "file protection stays anchored to its repo despite external cwd or symlinks" {
    local outside="${BATS_TEST_TMPDIR}/other-repo"
    git init -q "${outside}"
    ln -s "${WORK}" "${outside}/alias"
    MAIN="${outside}"
    _edit "${WORK}/file"
    assert_equal "${status}" 2
    _edit 'alias/new-file'
    assert_equal "${status}" 2
    _edit "${outside}/body.md"
    assert_success
}

@test "launcher wrappers and namespace spellings cannot hide restricted actions" {
    local command
    for command in 'timeout 60 env git commit -m fix' \
        'timeout 60 timeout 30 command git push' \
        'timeout 60 env just test unit' 'just test::unit' 'just test::lint'; do
        _check "${command}"
        assert_equal "${status}" 2
    done
    _check 'timeout 60 env git log'
    assert_success
}
