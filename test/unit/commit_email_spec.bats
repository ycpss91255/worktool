#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/commit_email_spec.bats - lib/commit_email.sh noreply email
# predicate (issue #234)
#
# Contract under test:
#   - a commit whose committer date is on or after the cutoff
#     2026-09-30T00:00:00Z passes only when BOTH its author and committer
#     email end with @users.noreply.github.com;
#   - a commit committed before the cutoff passes whatever its emails
#     (history made before the rule is never rewritten);
#   - a GitHub-generated commit (committer noreply@github.com, i.e.
#     web-flow: the merge button, web edits) passes: GitHub sets its emails;
#   - a record whose date is not a UTC `YYYY-MM-DDTHH:MM:SSZ` stamp fails
#     (fail closed: an unreadable date never skips the check);
#   - commit_email_evaluate reads one tab-separated record per line
#     (`<sha>\t<date>\t<author name>\t<author email>\t<committer name>\t
#     <committer email>`), lists every offending commit with sha, author
#     and emails plus the fix command, and exits 1; all clean exits 0;
#   - commit_email_range picks the commit range from the event data;
#   - the record format fed through a real `git log` round-trips;
#   - the library is pure: no GitHub API call, no `set`, nothing on stdout
#     at source time.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    # shellcheck source=../../lib/commit_email.sh
    source "${LIB_DIR}/commit_email.sh"
    NR='12345+someone@users.noreply.github.com'
    PLAIN='someone@example.com'
    AFTER='2026-09-30T00:00:00Z'
    LATER='2026-10-02T08:15:00Z'
    BEFORE='2026-09-29T23:59:59Z'
    ZERO='0000000000000000000000000000000000000000'
}

# Print one commit record: $1 sha, $2 date, $3 author email,
# $4 committer email (names are fixed).
_rec() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" 'Some One' "$3" 'Some One' "$4"
}

# --- required spec / library guard ------------------------------------------

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "commit_email.sh can be sourced without output and without changing shell options" {
    run bash -c 'before="$(set -o; shopt)"; source "$1"; after="$(set -o; shopt)"; [[ "${before}" == "${after}" ]]' \
        _ "${LIB_DIR}/commit_email.sh"
    assert_success
    assert_output ""
}

@test "commit_email.sh makes no GitHub API call (pure predicate)" {
    run grep -nE '(^|[^_[:alnum:]])(gh|curl|wget)([[:space:]]|$)' "${LIB_DIR}/commit_email.sh"
    assert_failure
}

@test "the cutoff is 2026-09-30T00:00:00Z" {
    run commit_email_cutoff
    assert_success
    assert_output '2026-09-30T00:00:00Z'
}

# --- commit_email_is_noreply --------------------------------------------------

@test "a users.noreply.github.com address is noreply" {
    run commit_email_is_noreply "${NR}"
    assert_success
    run commit_email_is_noreply 'someone@users.noreply.github.com'
    assert_success
}

@test "a plain address is not noreply" {
    run commit_email_is_noreply "${PLAIN}"
    assert_failure
}

@test "look-alike addresses are not noreply" {
    local _e
    for _e in '' '@users.noreply.github.com' 'x@users.noreply.github.com.evil.com' \
        'x@evilusers.noreply.github.com' 'x@noreply.github.com' 'noreply@github.com'; do
        run commit_email_is_noreply "${_e}"
        assert_failure
    done
}

# --- commit_email_commit_ok -----------------------------------------------------

@test "after the cutoff: author and committer both noreply pass" {
    run commit_email_commit_ok "${LATER}" "${NR}" "${NR}"
    assert_success
    run commit_email_commit_ok "${AFTER}" "${NR}" "${NR}"
    assert_success
}

@test "after the cutoff: a plain author email fails" {
    run commit_email_commit_ok "${LATER}" "${PLAIN}" "${NR}"
    assert_failure
}

@test "after the cutoff: a plain committer email fails" {
    run commit_email_commit_ok "${LATER}" "${NR}" "${PLAIN}"
    assert_failure
}

@test "exactly at the cutoff the rule already applies" {
    run commit_email_commit_ok "${AFTER}" "${PLAIN}" "${PLAIN}"
    assert_failure
}

@test "before the cutoff: plain emails pass (history is not rewritten)" {
    run commit_email_commit_ok "${BEFORE}" "${PLAIN}" "${PLAIN}"
    assert_success
}

@test "a GitHub-generated commit (committer noreply@github.com) passes" {
    run commit_email_commit_ok "${LATER}" "${NR}" 'noreply@github.com'
    assert_success
    run commit_email_commit_ok "${LATER}" "${PLAIN}" 'noreply@github.com'
    assert_success
}

@test "a malformed or non-UTC date fails closed" {
    local _d
    for _d in '' 'yesterday' '2026-10-02T08:15:00+08:00' '2026-10-02 08:15:00' \
        '1999-01-01T00:00:00'; do
        run commit_email_commit_ok "${_d}" "${NR}" "${NR}"
        assert_failure
    done
}

# --- commit_email_evaluate -----------------------------------------------------

@test "evaluate: no commit passes" {
    run commit_email_evaluate < /dev/null
    assert_success
}

@test "evaluate: every commit clean passes" {
    run commit_email_evaluate < <(_rec aaa1 "${LATER}" "${NR}" "${NR}"; _rec bbb2 "${BEFORE}" "${PLAIN}" "${PLAIN}")
    assert_success
    refute_output --partial 'aaa1'
    refute_output --partial 'bbb2'
}

@test "evaluate: an offending commit fails and is listed with sha, author and emails" {
    run commit_email_evaluate < <(_rec aaa1 "${LATER}" "${NR}" "${NR}"; _rec bbb2 "${LATER}" "${PLAIN}" "${NR}")
    assert_failure 1
    assert_output --partial 'bbb2'
    assert_output --partial 'Some One'
    assert_output --partial "${PLAIN}"
    refute_output --partial 'aaa1'
}

@test "evaluate: every offending commit is listed, not only the first" {
    run commit_email_evaluate < <(_rec ccc1 "${LATER}" "${PLAIN}" "${NR}"; _rec ddd2 "${LATER}" "${NR}" "${PLAIN}")
    assert_failure 1
    assert_output --partial 'ccc1'
    assert_output --partial 'ddd2'
}

@test "evaluate: the failure names the fix command" {
    run commit_email_evaluate < <(_rec bbb2 "${LATER}" "${PLAIN}" "${PLAIN}")
    assert_failure 1
    assert_output --partial 'users.noreply.github.com'
    assert_output --partial 'git commit --amend --no-edit --reset-author'
    assert_output --partial 'git push --force-with-lease'
}

@test "evaluate: the last record may lack its newline" {
    run commit_email_evaluate < <(printf '%s\t%s\t%s\t%s\t%s\t%s' eee5 "${LATER}" 'A' "${PLAIN}" 'A' "${NR}")
    assert_failure 1
    assert_output --partial 'eee5'
}

# --- commit_email_range ----------------------------------------------------------

@test "range: pull_request checks base..head" {
    run commit_email_range pull_request base1 head2 '' ''
    assert_success
    assert_output 'base1..head2'
}

@test "range: push checks before..after" {
    run commit_email_range push '' '' before1 after2
    assert_success
    assert_output 'before1..after2'
}

@test "range: push of a new ref (before is all zeros) checks the pushed commit alone" {
    run commit_email_range push '' '' "${ZERO}" after2
    assert_success
    assert_output 'after2^!'
}

@test "range: missing data or an unknown event fails" {
    run commit_email_range pull_request '' head2 '' ''
    assert_failure
    run commit_email_range push '' '' before1 ''
    assert_failure
    run commit_email_range workflow_dispatch a b c d
    assert_failure
}

# --- round trip through a real git log -------------------------------------------

@test "records from the CI git log command round-trip into evaluate" {
    local _repo="${BATS_TEST_TMPDIR}/repo" _base
    git init -q "${_repo}"
    # Pre-rule commit with a plain email: allowed.
    GIT_AUTHOR_NAME='Old' GIT_AUTHOR_EMAIL="${PLAIN}" \
        GIT_COMMITTER_NAME='Old' GIT_COMMITTER_EMAIL="${PLAIN}" \
        GIT_AUTHOR_DATE='2026-09-01T10:00:00+08:00' GIT_COMMITTER_DATE='2026-09-01T10:00:00+08:00' \
        git -C "${_repo}" commit -q --allow-empty -m base
    _base="$(git -C "${_repo}" rev-parse HEAD)"
    # 2026-09-30T07:00:00+08:00 is 2026-09-29T23:00:00Z: still before the cutoff.
    GIT_AUTHOR_NAME='Tz' GIT_AUTHOR_EMAIL="${PLAIN}" \
        GIT_COMMITTER_NAME='Tz' GIT_COMMITTER_EMAIL="${PLAIN}" \
        GIT_AUTHOR_DATE='2026-09-30T07:00:00+08:00' GIT_COMMITTER_DATE='2026-09-30T07:00:00+08:00' \
        git -C "${_repo}" commit -q --allow-empty -m tz
    GIT_AUTHOR_NAME='Good' GIT_AUTHOR_EMAIL="${NR}" \
        GIT_COMMITTER_NAME='Good' GIT_COMMITTER_EMAIL="${NR}" \
        GIT_AUTHOR_DATE='2026-10-01T10:00:00+08:00' GIT_COMMITTER_DATE='2026-10-01T10:00:00+08:00' \
        git -C "${_repo}" commit -q --allow-empty -m good
    run bash -c 'source "$1"; TZ=UTC git -C "$2" log --date=format-local:%Y-%m-%dT%H:%M:%SZ --format="$(commit_email_log_format)" "$3" | commit_email_evaluate' \
        _ "${LIB_DIR}/commit_email.sh" "${_repo}" "${_base}..HEAD"
    assert_success
    GIT_AUTHOR_NAME='Bad Author' GIT_AUTHOR_EMAIL="${PLAIN}" \
        GIT_COMMITTER_NAME='Good' GIT_COMMITTER_EMAIL="${NR}" \
        GIT_AUTHOR_DATE='2026-10-01T11:00:00+08:00' GIT_COMMITTER_DATE='2026-10-01T11:00:00+08:00' \
        git -C "${_repo}" commit -q --allow-empty -m bad
    run bash -c 'source "$1"; TZ=UTC git -C "$2" log --date=format-local:%Y-%m-%dT%H:%M:%SZ --format="$(commit_email_log_format)" "$3" | commit_email_evaluate' \
        _ "${LIB_DIR}/commit_email.sh" "${_repo}" "${_base}..HEAD"
    assert_failure 1
    assert_output --partial "$(git -C "${_repo}" rev-parse HEAD)"
    assert_output --partial 'Bad Author'
    refute_output --partial "$(git -C "${_repo}" rev-parse HEAD~1)"
}
