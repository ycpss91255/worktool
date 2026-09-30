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

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/hook"

setup() {
    REPO="${BATS_TEST_TMPDIR}/repo"
    git init -q -b main "${REPO}"
    git -C "${REPO}" config user.email t@e.st
    git -C "${REPO}" config user.name tester
    _put README.md 'readme'
    _commit init
}

@test "this spec is a required matrix spec of test.sh" {
    run bash -c 'source "$1" && _required_specs matrix' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "matrix/$(basename -- "${BATS_TEST_FILENAME}")"
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

@test "counts what a pathspec commit records: the named paths (--only) and, with -i, the index too" {
    _put lib/x.sh 'x() { :; }'
    _put test/unit/x_spec.bats '@test "x" { run x; }'
    _commit 'feat: x'
    printf 'y() { :; }\n' >> "${REPO}/lib/x.sh"
    printf '# y\n' >> "${REPO}/test/unit/x_spec.bats"
    git -C "${REPO}" add test/unit/x_spec.bats
    _check "git commit -m 'feat: y' lib/x.sh"
    assert_failure 2
    _check "git commit -m 'feat: y' --only -- lib/x.sh"
    assert_failure 2
    _check "git commit -i -m 'feat: y' lib/x.sh"
    assert_success
}

@test "judges the repo the launch runs in: git -C <dir>, git -c k=v, a cd before it" {
    _put lib/x.sh 'x() { :; }'
    local _away="${BATS_TEST_TMPDIR}/away" _c
    mkdir -p "${_away}"
    for _c in "git -C ${REPO} commit -m x" "git -c core.quotepath=off -C ${REPO} commit -m x" \
        "git -C ${BATS_TEST_TMPDIR} -C repo commit -m x" "cd ${REPO} && git commit -m x"; do
        run_hook enforce_tdd_commit \
            "$(jq -n --arg c "${_c}" --arg d "${_away}" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')"
        assert_failure 2
    done
}

# _scenario <name> - rebuild REPO in the state the named case commits from.
_scenario() {
    rm -rf "${REPO}"
    setup
    case "$1" in
        product+test) _put lib/x.sh 'x() { :; }'; _put test/unit/x_spec.bats '@test "x" { run x; }' ;;
        product-after-red) _put test/unit/x_spec.bats '@test "x" { run x; }'; _commit red; _put lib/x.sh 'x() { :; }' ;;
        product-after-green) _put lib/w.sh 'w() { :; }'; _put test/unit/w_spec.bats '@test "w" { run w; }'
            _commit green; _put lib/x.sh 'x() { :; }' ;;
        one-test) _put test/unit/x_spec.bats '@test "a" { :; }' ;;
        two-tests) _put test/unit/x_spec.bats "$(printf '@test "a" { :; }\n@test "b" { :; }')" ;;
        docs) _put doc/x.md 'x' ;;
        merge) git -C "${REPO}" checkout -q -b feat; _put lib/x.sh 'x() { :; }'; _commit f
            git -C "${REPO}" checkout -q main; _put doc/y.md 'y'; _commit d
            git -C "${REPO}" merge -q --no-ff --no-commit feat ;;
    esac
}

@test "the acceptance matrix holds for a direct launch, bash -c and eval" {
    local _case _want _form
    while read -r _case _want; do
        for _form in "git commit -m x" "bash -c 'git commit -m x'" "eval git commit -m x"; do
            if [[ -n "${TDD_MATRIX_CASE:-}" && "${_case}" != "${TDD_MATRIX_CASE}" ]]; then
                continue
            fi
            if [[ -n "${TDD_MATRIX_FORM:-}" && "${_form}" != "${TDD_MATRIX_FORM}" ]]; then
                continue
            fi
            _scenario "${_case}"
            _check "${_form}"
            [[ "${status}" -eq "${_want}" ]] \
                || fail "${_case} via [${_form}]: want exit ${_want}, got ${status}: ${output}"
        done
    done <<'CASES'
product+test 0
product-after-red 0
product-after-green 2
one-test 0
two-tests 2
docs 0
merge 0
CASES
}

@test "ignores text that only mentions git commit, other git launches and a cwd outside any repo" {
    _put lib/x.sh 'x() { :; }'
    local _c
    for _c in "echo 'git commit -m x'" "git log --grep='git commit'" "git status" \
        "gh pr create --title 'x' --body 'run git commit -m x'" "$(printf 'cat <<EOF\ngit commit -m x\nEOF')"; do
        _check "${_c}"
        assert_success
        assert_output ""
    done
    run_hook enforce_tdd_commit \
        "$(jq -n --arg d "${BATS_TEST_TMPDIR}" '{tool_name:"Bash", cwd:$d, tool_input:{command:"git commit -m x"}}')"
    assert_success
}
