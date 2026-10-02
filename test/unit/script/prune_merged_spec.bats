#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"

setup() {
    FIXTURE="${BATS_TEST_TMPDIR}/fixture"
    MAIN="${FIXTURE}/src"
    TREE="${FIXTURE}/worktree/topic"
    mkdir -p "${FIXTURE}"
    git init -q --bare "${FIXTURE}/remote"
    git init -q -b main "${MAIN}"
    git -C "${MAIN}" config user.email tester@users.noreply.github.com
    git -C "${MAIN}" config user.name tester
    printf '.agents/state/\n' > "${MAIN}/.gitignore"
    git -C "${MAIN}" add .
    git -C "${MAIN}" commit -qm init
    git -C "${MAIN}" remote add origin "${FIXTURE}/remote"
    git -C "${MAIN}" push -qu origin main
    git -C "${MAIN}" worktree add -qb topic "${TREE}"
}

prune() {
    run bash -c 'cd "$1"; bash "$2" "${@:3}"' _ "${MAIN}" \
        "${REPO_ROOT}/.agents/script/worktree/prune-merged.sh" "$@"
}

@test "dry-run lists merged clean worktree without deleting it" {
    prune
    assert_success
    assert_output --partial "${TREE}"
    [ -d "${TREE}" ]
    git -C "${MAIN}" show-ref --verify refs/heads/topic
}

@test "apply deletes merged clean worktree and its local branch" {
    prune --apply
    assert_success
    [ ! -e "${TREE}" ]
    run git -C "${MAIN}" show-ref --verify refs/heads/topic
    assert_failure
}
