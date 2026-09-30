#!/usr/bin/env bats
# Full product matrices for the main-checkout read-only hook (issue #276).

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/hook"

setup() {
    MAIN_REPO="${BATS_TEST_TMPDIR}/main"
    LINKED_REPO="${MAIN_REPO}/.worktree/linked"
    OUTSIDE="${BATS_TEST_TMPDIR}/outside"
    mkdir -p "${MAIN_REPO}" "${OUTSIDE}"
    git -C "${MAIN_REPO}" init -q
    git -C "${MAIN_REPO}" config user.email test@example.com
    git -C "${MAIN_REPO}" config user.name Test
    printf 'base\n' >"${MAIN_REPO}/tracked.txt"
    git -C "${MAIN_REPO}" add tracked.txt
    git -C "${MAIN_REPO}" commit -qm base
    git -C "${MAIN_REPO}" worktree add -q -b linked "${LINKED_REPO}"
    mkdir -p "${MAIN_REPO}/.agents/memory"
}

_edit_payload() {
    jq -n --arg tool "$1" --arg path "$2" --arg cwd "${MAIN_REPO}" '{
        cwd:$cwd, tool_name:$tool, tool_input:{file_path:$path}
    }'
}

_bash_payload() {
    jq -n --arg command "$1" --arg cwd "$2" '{
        cwd:$cwd, tool_name:"Bash", tool_input:{command:$command}
    }'
}

_wrapped() {
    case "$1" in
        direct) printf '%s\n' "$2" ;;
        bash-c) printf "bash -c %q\n" "$2" ;;
        eval) printf "eval %q\n" "$2" ;;
    esac
}

_directory_wrapped() {
    local _change="cd $2" _git='git commit'
    case "$1" in
        direct) printf '%s && %s\n' "${_change}" "${_git}" ;;
        bash-c) printf "bash -c %q\n" "${_change} && ${_git}" ;;
        eval) printf "eval %q\n" "${_change} && ${_git}" ;;
        subshell) printf '(%s; %s)\n' "${_change}" "${_git}" ;;
    esac
}

@test "matrix: file location x Edit Write MultiEdit" {
    local _tool _kind _path _expected
    for _tool in Edit Write MultiEdit; do
        for _kind in main worktree memory outside; do
            case "${_kind}" in
                main) _path="${MAIN_REPO}/blocked.txt"; _expected=2 ;;
                worktree) _path="${LINKED_REPO}/allowed.txt"; _expected=0 ;;
                memory) _path="${MAIN_REPO}/.agents/memory/allowed.md"; _expected=0 ;;
                outside) _path="${OUTSIDE}/allowed.txt"; _expected=0 ;;
            esac
            run_hook enforce_main_checkout_readonly "$(_edit_payload "${_tool}" "${_path}")"
            if (( _expected == 2 )); then
                assert_failure 2
                assert_output --partial "main checkout"
            else
                assert_success
            fi
        done
    done
}

@test "matrix: mutating git command x main worktree git-C x direct bash-c eval" {
    local _operation _place _wrapper _cwd _command
    local -a _operations=(
        commit 'commit -C HEAD' merge rebase reset cherry-pick revert am apply
        'stash pop' 'stash apply' 'checkout topic' 'checkout -- tracked.txt'
        'switch topic' restore clean
    )
    for _operation in "${_operations[@]}"; do
        for _place in main worktree git-C; do
            for _wrapper in direct bash-c eval; do
                case "${_place}" in
                    main) _cwd="${MAIN_REPO}"; _command="git ${_operation}" ;;
                    worktree) _cwd="${LINKED_REPO}"; _command="git ${_operation}" ;;
                    git-C) _cwd="${OUTSIDE}"; _command="git -C ${MAIN_REPO} ${_operation}" ;;
                esac
                run_hook enforce_main_checkout_readonly \
                    "$(_bash_payload "$(_wrapped "${_wrapper}" "${_command}")" "${_cwd}")"
                if [[ "${_place}" == worktree ]]; then
                    assert_success
                else
                    assert_failure 2
                    assert_output --partial "main checkout"
                fi
            done
        done
    done
}

@test "matrix: allowed git command x main worktree git-C x direct bash-c eval" {
    local _operation _place _wrapper _cwd _command
    local -a _operations=(
        fetch 'pull --ff-only' 'worktree add /tmp/new' 'worktree remove /tmp/old'
        'worktree prune' 'worktree list' status log diff show 'checkout main'
        'checkout -q main' 'switch main' 'switch --no-guess main'
    )
    for _operation in "${_operations[@]}"; do
        for _place in main worktree git-C; do
            for _wrapper in direct bash-c eval; do
                case "${_place}" in
                    main) _cwd="${MAIN_REPO}"; _command="git ${_operation}" ;;
                    worktree) _cwd="${LINKED_REPO}"; _command="git ${_operation}" ;;
                    git-C) _cwd="${OUTSIDE}"; _command="git -C ${MAIN_REPO} ${_operation}" ;;
                esac
                run_hook enforce_main_checkout_readonly \
                    "$(_bash_payload "$(_wrapped "${_wrapper}" "${_command}")" "${_cwd}")"
                assert_success
            done
        done
    done
}

@test "matrix: directory change x main worktree x direct bash-c eval subshell" {
    local _destination _wrapper _cwd _target
    for _destination in worktree main; do
        for _wrapper in direct bash-c eval subshell; do
            case "${_destination}" in
                worktree) _cwd="${MAIN_REPO}"; _target="${LINKED_REPO}" ;;
                main) _cwd="${LINKED_REPO}"; _target="${MAIN_REPO}" ;;
            esac
            run_hook enforce_main_checkout_readonly \
                "$(_bash_payload "$(_directory_wrapped "${_wrapper}" "${_target}")" "${_cwd}")"
            if [[ "${_destination}" == worktree ]]; then
                assert_success
            else
                assert_failure 2
                assert_output --partial "main checkout"
            fi
        done
    done
}

@test "pushd uses its literal destination for a mutating git command" {
    run_hook enforce_main_checkout_readonly \
        "$(_bash_payload "pushd ${LINKED_REPO}; git commit" "${MAIN_REPO}")"
    assert_success

    run_hook enforce_main_checkout_readonly \
        "$(_bash_payload "pushd ${MAIN_REPO}; git commit" "${LINKED_REPO}")"
    assert_failure 2
    assert_output --partial "main checkout"
}

@test "a child-scope directory change does not affect a later outer git command" {
    local _command
    local -a _commands=(
        "(cd ${LINKED_REPO}; git status); git commit -m x"
        "cd ${LINKED_REPO} | true; git commit -m x"
        "bash -c 'cd ${LINKED_REPO}'; git commit -m x"
    )
    for _command in "${_commands[@]}"; do
        run_hook enforce_main_checkout_readonly \
            "$(_bash_payload "${_command}" "${MAIN_REPO}")"
        assert_failure 2
        assert_output --partial "main checkout"
    done
}

@test "non-top-level directory changes fail closed before a mutating git command" {
    local _command
    local -a _commands=(
        "cd ${LINKED_REPO} & git commit -m x"
        "cd ${LINKED_REPO} & wait; git commit -m x"
        "{ cd ${LINKED_REPO}; } | true; git commit -m x"
        "echo \"(\"; { cd ${LINKED_REPO}; } | cat; git commit -m x"
        "env cd ${LINKED_REPO}; git commit -m x"
    )
    for _command in "${_commands[@]}"; do
        run_hook enforce_main_checkout_readonly \
            "$(_bash_payload "${_command}" "${MAIN_REPO}")"
        assert_failure 2
        assert_output --partial "split the call or use git -C"
    done
}

@test "builtin cd changes the directory for a later git command" {
    run_hook enforce_main_checkout_readonly \
        "$(_bash_payload "builtin cd ${MAIN_REPO} && git commit -m x" "${LINKED_REPO}")"
    assert_failure 2
    assert_output --partial "main checkout"
}

@test "a dynamic directory fails closed only for a mutating git command" {
    local _d='$'
    run_hook enforce_main_checkout_readonly \
        "$(_bash_payload "cd \"${_d}TARGET\"; git status" "${LINKED_REPO}")"
    assert_success

    run_hook enforce_main_checkout_readonly \
        "$(_bash_payload "cd \"${_d}TARGET\"; git commit" "${LINKED_REPO}")"
    assert_failure 2
    assert_output --partial "working directory is dynamic"
}

@test "gh is allowed from the main checkout" {
    run_hook enforce_main_checkout_readonly \
        "$(_bash_payload 'gh issue view 276 --repo ycpss91255/worktool' "${MAIN_REPO}")"
    assert_success
}
