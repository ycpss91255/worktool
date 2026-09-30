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
