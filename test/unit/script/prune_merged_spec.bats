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

merge_topic() {
    git -C "${TREE}" commit -qm feature --allow-empty
    git -C "${MAIN}" merge -q --ff-only topic
    git -C "${MAIN}" push -q origin main
}

@test "keeps newly created zero-commit branch worktree" {
    prune --apply
    assert_success
    [ -d "${TREE}" ]
    git -C "${MAIN}" show-ref --verify refs/heads/topic
    assert_output --partial "no commits since worktree creation"
}

@test "dry-run lists merged clean worktree without deleting it" {
    merge_topic
    prune
    assert_success
    assert_output --partial "${TREE}"
    [ -d "${TREE}" ]
    git -C "${MAIN}" show-ref --verify refs/heads/topic
}

@test "removes a clean detached worktree already merged into origin main" {
    merge_topic
    local detached="${FIXTURE}/worktree/detached"
    git -C "${MAIN}" worktree add -q --detach "${detached}" origin/main
    prune
    assert_success
    assert_output --partial "${detached}"
    [ -d "${detached}" ]
    prune --apply
    assert_success
    [ ! -e "${detached}" ]
}

@test "apply deletes merged clean worktree and its local branch" {
    merge_topic
    prune --apply
    assert_success
    [ ! -e "${TREE}" ]
    run git -C "${MAIN}" show-ref --verify refs/heads/topic
    assert_failure
}

@test "keeps unmerged pushed commits and explains why on stderr" {
    git -C "${TREE}" commit -qm feature --allow-empty
    git -C "${TREE}" push -qu origin topic
    prune --apply
    assert_success
    assert_output --partial "not merged"
    [ -d "${TREE}" ]
}

@test "keeps a newly created detached worktree whose HEAD is not merged" {
    git -C "${TREE}" commit -qm feature --allow-empty
    git -C "${TREE}" push -qu origin topic
    local detached="${FIXTURE}/worktree/detached"
    git -C "${MAIN}" worktree add -q --detach "${detached}" topic
    prune --apply
    assert_success
    assert_output --partial "kept ${detached}: not merged"
    [ -d "${detached}" ]
}

@test "keeps tracked staged and untracked changes" {
    merge_topic
    local change
    for change in tracked staged untracked; do
        case "${change}" in
            tracked) printf 'changed\n' >> "${TREE}/.gitignore" ;;
            staged) git -C "${TREE}" add .gitignore ;;
            untracked)
                git -C "${TREE}" restore --staged .gitignore
                git -C "${TREE}" restore .gitignore
                printf 'unsaved\n' > "${TREE}/notes"
                ;;
        esac
        prune --apply
        assert_success
        assert_output --partial "uncommitted changes"
        [ -d "${TREE}" ]
    done
}

@test "keeps local unpushed commits with a specific reason" {
    git -C "${TREE}" push -qu origin topic
    git -C "${TREE}" commit -qm local --allow-empty
    prune --apply
    assert_success
    assert_output --partial "unpushed commits"
    [ -d "${TREE}" ]
}

@test "explains retention of main checkout and worktrees outside sibling directory" {
    git -C "${MAIN}" worktree add -qb outside "${FIXTURE}/outside"
    prune --apply
    assert_success
    assert_output --partial "main checkout"
    assert_output --partial "outside sibling worktree/"
    [ -d "${MAIN}/.git" ]
    [ -d "${FIXTURE}/outside" ]
}

@test "fetches acceptance branch and removes its merged detached worktree" {
    git -C "${TREE}" commit -qm accepted --allow-empty
    git -C "${TREE}" push -q origin HEAD:refs/heads/m3/5-acceptance
    local detached="${FIXTURE}/worktree/detached"
    git -C "${MAIN}" worktree add -q --detach "${detached}" topic
    git -C "${MAIN}" update-ref -d refs/remotes/origin/m3/5-acceptance
    prune --apply
    assert_success
    [ ! -e "${detached}" ]
    [ ! -e "${TREE}" ]
}

@test "only ignored agent state is exempt from cleanliness checks" {
    printf 'cache/\n' >> "${TREE}/.gitignore"
    git -C "${TREE}" add .gitignore
    git -C "${TREE}" commit -qm ignore
    git -C "${TREE}" push -q origin HEAD:main
    mkdir -p "${TREE}/cache" "${TREE}/.agents/state"
    printf state > "${TREE}/.agents/state/runtime"
    printf cache > "${TREE}/cache/data"
    prune --apply
    assert_success
    assert_output --partial "uncommitted changes"
    [ -d "${TREE}" ]
    rm -r "${TREE}/cache"
    prune --apply
    assert_success
    [ ! -e "${TREE}" ]
}

@test "cleanup can remove its invoking worktree and still delete the branch" {
    merge_topic
    run bash -c 'cd "$1"; bash "$2" --apply' _ "${TREE}" \
        "${REPO_ROOT}/.agents/script/worktree/prune-merged.sh"
    assert_success
    [ ! -e "${TREE}" ]
    run git -C "${MAIN}" show-ref --verify refs/heads/topic
    assert_failure
}

@test "keeps locked worktrees with an explanation and continues cleanup" {
    git -C "${MAIN}" worktree lock "${TREE}" --reason retained
    git -C "${MAIN}" worktree add -qb other "${FIXTURE}/worktree/other"
    git -C "${FIXTURE}/worktree/other" commit -qm other --allow-empty
    git -C "${MAIN}" merge -q --ff-only other
    git -C "${MAIN}" push -q origin main
    prune --apply
    assert_success
    assert_output --partial "locked"
    [ -d "${TREE}" ]
    [ ! -e "${FIXTURE}/worktree/other" ]
}

@test "deleted remote acceptance branches cannot authorize cleanup" {
    git -C "${TREE}" commit -qm feature --allow-empty
    git -C "${TREE}" push -qu origin topic
    git -C "${TREE}" push -q origin HEAD:refs/heads/m3/5-acceptance
    git --git-dir="${FIXTURE}/remote" update-ref -d refs/heads/m3/5-acceptance
    prune --apply
    assert_success
    assert_output --partial "not merged"
    [ -d "${TREE}" ]
}

@test "just forwards arguments and script help explains the cleanup contract" {
    run just --justfile "${REPO_ROOT}/justfile" worktree prune-merged --help --bogus
    assert_failure
    assert_output --partial "prune-merged.sh: unknown option '--bogus' (see --help)"
    refute_output --partial "Usage:"
    run just --justfile "${REPO_ROOT}/justfile" worktree prune-merged --help
    assert_success
    assert_output --partial "origin/main"
    assert_output --partial ".agents/state/"
}

@test "ignored state exemption handles quoted and newline filenames" {
    merge_topic
    mkdir -p "${TREE}/.agents/state"
    printf state > "${TREE}/.agents/state/中文"
    printf state > "${TREE}/.agents/state/"$'line\nbreak'
    prune --apply
    assert_success
    [ ! -e "${TREE}" ]
}
