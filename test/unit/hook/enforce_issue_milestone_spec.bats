#!/usr/bin/env bats
# test/unit/hook/enforce_issue_milestone_spec.bats -
# .agents/hook/enforce_issue_milestone.sh
#
# Issue #266: an issue that belongs to a milestone gets that milestone, one
# that does not gets none, and the filer must say which when filing it. A
# real `gh issue create` launch (also inside bash -c / eval) is BLOCKED
# (exit 2) unless it carries exactly one of: --milestone <name> / -m
# <name>, or a body line `milestone: 無` (inline --body, --body-file, or a
# stdin body). Both at once contradict each other and are blocked too. The
# milestone name is not checked (gh rejects an unknown one); gh issue edit
# and gh pr create are not judged.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

_check() { run_hook enforce_issue_milestone "$(hook_json "$1")"; }

_check_in() {
    run_hook enforce_issue_milestone \
        "$(jq -n --arg c "$2" --arg d "$1" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')"
}

# _wrap <direct|bash|eval> <command> - the command launched directly, by
# bash -c "..." or by eval "..." (the command uses no double quote).
_wrap() {
    case "$1" in
        direct) printf '%s' "$2" ;;
        bash) printf 'bash -c "%s"' "$2" ;;
        eval) printf 'eval "%s"' "$2" ;;
    esac
}

setup() {
    NONE="${BATS_TEST_TMPDIR}/none.md"
    PLAIN="${BATS_TEST_TMPDIR}/plain.md"
    printf '## 問題\n\nx\n\nmilestone: 無\n' > "${NONE}"
    printf '## 問題\n\nx\n' > "${PLAIN}"
    GH="gh issue create -R ycpss91255/worktool --title 'x' --label bug"
}

# _allowed <command> - each wrapper form of <command> passes silently.
_allowed() {
    local _how
    for _how in direct bash eval; do
        _check "$(_wrap "${_how}" "$1")"
        assert_success
        assert_output ""
    done
}

# _blocked <command> <text> - each wrapper form is blocked (exit 2) with
# <text> in the message.
_blocked() {
    local _how
    for _how in direct bash eval; do
        _check "$(_wrap "${_how}" "$1")"
        assert_failure 2
        assert_output --partial "$2"
    done
}

# --- allowed: exactly one declaration ------------------------------------------

@test "allows --milestone <name>, --milestone=<name>, -m <name> and -m<name>" {
    _allowed "${GH} --milestone 'M3 效能' --body-file ${PLAIN}"
    _allowed "${GH} --milestone=M3 --body-file ${PLAIN}"
    _allowed "${GH} -m M3 --body-file ${PLAIN}"
    _allowed "${GH} -mM3 -F ${PLAIN}"
}

@test "allows a body line 'milestone: 無' from --body / -b / --body=" {
    _allowed "${GH} --body 'milestone: 無'"
    _allowed "${GH} -b 'milestone: 無'"
    _allowed "${GH} --body='milestone: 無'"
}

@test "allows a body line 'milestone: 無' from --body-file / -F / --body-file=" {
    _allowed "${GH} --body-file ${NONE}"
    _allowed "${GH} -F ${NONE}"
    _allowed "${GH} --body-file=${NONE}"
}

@test "allows a body line 'milestone: 無' from stdin: a heredoc or one cat'ed file" {
    _allowed "$(printf "%s -F - <<'EOF'\n## 問題\n\nmilestone: 無\nEOF" "${GH}")"
    _allowed "cat ${NONE} | ${GH} --body-file -"
}

@test "the no-milestone line may use a full-width colon and surrounding blanks" {
    _allowed "$(printf "%s -F - <<'EOF'\nx\n  milestone：無  \nEOF" "${GH}")"
}

@test "resolves a relative body file against the tool call's cwd" {
    cp "${NONE}" "${BATS_TEST_TMPDIR}/rel.md"
    _check_in "${BATS_TEST_TMPDIR}" "${GH} --body-file rel.md"
    assert_success
    assert_output ""
}

# --- blocked: no declaration ---------------------------------------------------

@test "blocks an issue with neither --milestone nor 'milestone: 無', naming both forms" {
    _blocked "${GH} --body-file ${PLAIN}" "--milestone"
    _blocked "${GH} --body-file ${PLAIN}" "milestone: 無"
    _blocked "${GH} --body 'no declaration'" "--milestone"
    _blocked "$(printf "%s -F - <<'EOF'\nno declaration\nEOF" "${GH}")" "--milestone"
    _blocked "cat ${PLAIN} | ${GH} -F -" "--milestone"
}

@test "blocks an empty milestone value" {
    _blocked "${GH} --milestone '' --body-file ${PLAIN}" "--milestone"
    _blocked "${GH} --milestone= --body-file ${PLAIN}" "--milestone"
}

@test "'milestone: 無' counts only as a line of its own" {
    _blocked "${GH} --body 'we say milestone: 無 here'" "--milestone"
    _blocked "${GH} --body 'milestone: 無 yet'" "--milestone"
}

@test "a body that cannot be read or seen does not count as 'milestone: 無'" {
    _blocked "${GH} --body-file ${BATS_TEST_TMPDIR}/missing.md" "--milestone"
    _blocked "printf 'milestone: 無' | ${GH} -F -" "--milestone"
}

@test "'milestone: 無' elsewhere in the command is not the body" {
    _check "$(printf "cat > /tmp/b.md <<'EOF'\nmilestone: 無\nEOF\n%s --body-file %s" "${GH}" "${PLAIN}")"
    assert_failure 2
    _check "echo 'milestone: 無'; ${GH} --body-file ${PLAIN}"
    assert_failure 2
}

# --- blocked: both -------------------------------------------------------------

@test "blocks --milestone together with 'milestone: 無' as a contradiction" {
    _blocked "${GH} --milestone M3 --body-file ${NONE}" "contradict"
    _blocked "${GH} -m M3 --body 'milestone: 無'" "contradict"
    _blocked "$(printf "%s -m M3 -F - <<'EOF'\nmilestone: 無\nEOF" "${GH}")" "contradict"
    _blocked "cat ${NONE} | ${GH} --milestone=M3 -F -" "contradict"
}

@test "judges every launch: one undeclared launch among declared ones blocks" {
    _check "${GH} -m M3 --body-file ${PLAIN} && ${GH} --body-file ${PLAIN}"
    assert_failure 2
}

# --- not judged ----------------------------------------------------------------

@test "gh issue edit, gh pr create, quoted mentions and non-gh commands pass" {
    _allowed "gh issue edit 5 -R ycpss91255/worktool --title 'x'"
    _allowed "gh pr create -R ycpss91255/worktool --title 'x' --body-file ${PLAIN}"
    _check "git commit -m 'gh issue create --title x'"
    assert_success
    assert_output ""
    _check "$(printf "cat > /tmp/b.md <<'EOF'\ngh issue create --title x\nEOF")"
    assert_success
    assert_output ""
    _check "git status"
    assert_success
    assert_output ""
}

@test "an empty payload passes" {
    run_hook enforce_issue_milestone '{}'
    assert_success
    assert_output ""
}
