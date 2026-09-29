#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/approval_spec.bats - lib/approval.sh milestone-gate approval
# predicate (issue #187)
#
# Contract under test:
#   - a PR without the `milestone-gate` label passes (not an acceptance PR);
#   - a labelled PR passes only when at least one comment is a human
#     approval: author_association OWNER, body (leading whitespace ignored)
#     not starting with `[claude]` or `[codex]`, body containing 允許合併;
#   - otherwise it fails, and the reason names what is missing;
#   - the predicate is pure: labels come in as an argument, comments as
#     NUL-terminated `<author_association>\t<body>` records on stdin; no
#     GitHub API call, no `set`, nothing on stdout at source time.
#
# Every case feeds plain data; nothing touches the network.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    # shellcheck source=../../lib/approval.sh
    source "${LIB_DIR}/approval.sh"
    PHRASE='允許合併'
    MISSING='需要維護者留言:允許合併'
}

# Print one comment record: $1 = author_association, $2 = body.
_rec() {
    printf '%s\t%s\0' "$1" "$2"
}

# --- required spec / library guard ------------------------------------------

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "approval.sh can be sourced without output and without changing shell options" {
    run bash -c 'before="$(set -o; shopt)"; source "$1"; after="$(set -o; shopt)"; [[ "${before}" == "${after}" ]]' \
        _ "${LIB_DIR}/approval.sh"
    assert_success
    assert_output ""
}

@test "approval.sh makes no GitHub API call (pure predicate)" {
    run grep -nE '(^|[^_[:alnum:]])(gh|curl|wget)([[:space:]]|$)' "${LIB_DIR}/approval.sh"
    assert_failure
}

# --- no label ----------------------------------------------------------------

@test "no milestone-gate label: passes without any comment" {
    run approval_evaluate $'bug\nenhancement' < /dev/null
    assert_success
    assert_output --partial 'milestone-gate'
}

@test "no label at all: passes" {
    run approval_evaluate '' < /dev/null
    assert_success
}

@test "a label that only resembles milestone-gate does not make it an acceptance PR" {
    run approval_evaluate $'milestone-gate-x\nx-milestone-gate' < /dev/null
    assert_success
}

# --- label without approval --------------------------------------------------

@test "label without any comment: fails and names what is missing" {
    run approval_evaluate $'enhancement\nmilestone-gate' < /dev/null
    assert_failure 1
    assert_output "${MISSING}"
}

@test "label with an OWNER comment that lacks the phrase: fails" {
    run approval_evaluate 'milestone-gate' < <(_rec OWNER 'looks good, merge later')
    assert_failure 1
    assert_output "${MISSING}"
}

# --- approver is not OWNER ---------------------------------------------------

@test "the phrase from a non-OWNER author does not count" {
    local _assoc
    for _assoc in MEMBER COLLABORATOR CONTRIBUTOR FIRST_TIME_CONTRIBUTOR NONE owner ''; do
        run approval_evaluate 'milestone-gate' < <(_rec "${_assoc}" "${PHRASE}")
        assert_failure 1
        assert_output "${MISSING}"
    done
}

# --- agent-marked comments ---------------------------------------------------

@test "a [claude]-prefixed comment containing the phrase does not count" {
    run approval_evaluate 'milestone-gate' < <(_rec OWNER "[claude] 維護者說${PHRASE}")
    assert_failure 1
    assert_output "${MISSING}"
}

@test "a [codex]-prefixed comment containing the phrase does not count" {
    run approval_evaluate 'milestone-gate' < <(_rec OWNER "[codex] ${PHRASE}")
    assert_failure 1
    assert_output "${MISSING}"
}

@test "leading whitespace before the agent marker does not hide it" {
    run approval_evaluate 'milestone-gate' < <(_rec OWNER $'\n  [claude] '"${PHRASE}")
    assert_failure 1
}

# --- correct human approval --------------------------------------------------

@test "an OWNER comment containing the phrase passes" {
    run approval_evaluate 'milestone-gate' < <(_rec OWNER "實機驗收通過,${PHRASE}。")
    assert_success
    assert_output --partial "${PHRASE}"
}

@test "the phrase on a later line of a multi-line body with tabs still passes" {
    run approval_evaluate 'milestone-gate' < <(_rec OWNER $'checklist done\n\tall\tgreen\n'"${PHRASE}")
    assert_success
}

@test "an agent marker later in the body does not disqualify a human comment" {
    run approval_evaluate 'milestone-gate' < <(_rec OWNER "${PHRASE}(回覆 [claude] 的整理)")
    assert_success
}

@test "one human approval among agent and non-OWNER comments passes" {
    run approval_evaluate $'milestone-gate\nenhancement' < <(
        _rec OWNER "[claude] 請維護者留言${PHRASE}"
        _rec NONE "${PHRASE}"
        _rec OWNER "${PHRASE}"
        _rec OWNER '[codex] 可合併'
    )
    assert_success
}

@test "the last record passes even without a trailing NUL" {
    run approval_evaluate 'milestone-gate' < <(_rec OWNER 'x'; printf 'OWNER\t%s' "${PHRASE}")
    assert_success
}

# --- the per-comment predicate ----------------------------------------------

@test "approval_is_human_approval is the per-comment rule" {
    run approval_is_human_approval OWNER "${PHRASE}"
    assert_success
    run approval_is_human_approval MEMBER "${PHRASE}"
    assert_failure
    run approval_is_human_approval OWNER "[codex] ${PHRASE}"
    assert_failure
    run approval_is_human_approval OWNER 'ok'
    assert_failure
}
