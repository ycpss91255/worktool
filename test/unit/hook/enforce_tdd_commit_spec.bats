#!/usr/bin/env bats
# test/unit/hook/enforce_tdd_commit_spec.bats - .agents/hook/enforce_tdd_commit.sh
#
# Issue #268: every implementation follows the tdd skill
# (.agents/skills/tdd/SKILL.md). A `git commit` launch is judged by what the
# commit would record:
#   - BLOCKED (exit 2, reason on stderr) when it touches product code but no
#     test, unless HEAD is a RED commit (tests only);
#   - BLOCKED when it touches tests only and adds more than one @test
#     (vertical slices: one behaviour at a time);
#   - allowed for a merge commit, a docs-only commit and an --amend that
#     only rewords.
# Each case builds a real throwaway git repo and passes it as the tool
# call's cwd.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    REPO="${BATS_TEST_TMPDIR}/repo"
    git init -q -b main "${REPO}"
    git -C "${REPO}" config user.email t@e.st
    git -C "${REPO}" config user.name tester
    _put README.md 'readme'
    _commit init
}

# _put <path> <content> - write a file in the repo and stage it.
_put() {
    mkdir -p "$(dirname -- "${REPO}/$1")"
    printf '%s\n' "$2" > "${REPO}/$1"
    git -C "${REPO}" add -- "$1"
}

_commit() { git -C "${REPO}" commit -q -m "$1"; }

# _check <command> - run the hook on <command>, the repo as the cwd.
_check() {
    run_hook enforce_tdd_commit \
        "$(jq -n --arg c "$1" --arg d "${REPO}" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')"
}

@test "blocks a commit that touches product code without a test when HEAD is not a RED commit" {
    _put lib/x.sh 'x() { :; }'
    _check "git commit -m 'feat: x'"
    assert_failure 2
    assert_output --partial "BLOCKED"
    assert_output --partial ".agents/skills/tdd/SKILL.md"
}

@test "allows a product-only GREEN commit right after a RED commit that touched only tests" {
    _put test/unit/x_spec.bats '@test "x" { run x; }'
    _commit 'test: x (RED)'
    _put lib/x.sh 'x() { :; }'
    _check "git commit -m 'feat: x (GREEN)'"
    assert_success
    assert_output ""
}

@test "blocks a tests-only commit that adds more than one @test" {
    _put test/unit/x_spec.bats "$(printf '@test "a" { :; }\n@test "b" { :; }')"
    _check "git commit -m 'test: a and b'"
    assert_failure 2
    assert_output --partial "@test"
    assert_output --partial ".agents/skills/tdd/SKILL.md"
}

@test "allows a tests-only commit that moves existing @test cases to another file" {
    _put test/unit/x_spec.bats "$(printf '@test "a" { :; }\n@test "b" { :; }')"
    _commit 'test: a and b'
    git -C "${REPO}" mv test/unit/x_spec.bats test/unit/y_spec.bats
    _check "git commit -m 'test: move a and b'"
    assert_success
    assert_output ""
}

@test "allows a docs-only commit, even a Markdown file under a product directory" {
    _put doc/x.md 'x'
    _put .agents/skills/x/SKILL.md 'x'
    _put .agents/memory/x.md 'x'
    _put script/box/README.md 'x'
    _check "git commit -m 'docs: x'"
    assert_success
    assert_output ""
}

@test "allows concluding a merge (MERGE_HEAD exists) that brings in product code only" {
    git -C "${REPO}" checkout -q -b feat
    _put lib/x.sh 'x() { :; }'
    _commit 'feat: x'
    git -C "${REPO}" checkout -q main
    _put doc/y.md 'y'
    _commit 'docs: y'
    git -C "${REPO}" merge -q --no-ff --no-commit feat
    _check "git commit -m 'Merge branch feat'"
    assert_success
    assert_output ""
}

@test "judges --amend by the whole amended commit: a second @test amended in is blocked, a reword is not" {
    _put test/unit/x_spec.bats '@test "a" { :; }'
    _commit 'test: a'
    _check "git commit --amend -m 'test: a, reworded'"
    assert_success
    printf '@test "b" { :; }\n' >> "${REPO}/test/unit/x_spec.bats"
    git -C "${REPO}" add test/unit/x_spec.bats
    _check "git commit --amend --no-edit"
    assert_failure 2
    assert_output --partial "adds 2 @test"
}

@test "counts the tracked changes that -a / --all / -am would commit, staged or not" {
    _put lib/x.sh 'x() { :; }'
    _commit 'feat: x'
    printf 'y() { :; }\n' >> "${REPO}/lib/x.sh"
    local _c
    for _c in "git commit -a -m 'feat: y'" "git commit --all -m 'feat: y'" "git commit -am 'feat: y'"; do
        _check "${_c}"
        assert_failure 2
        assert_output --partial "no test"
    done
}
