#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/commit_email_spec.bats - lib/commit_email.sh noreply email
# predicate (issue #234)
#
# Contract under test:
#   - every commit in the checked range passes only when its author email
#     ends with @users.noreply.github.com; its committer email must be a
#     noreply address too, or exactly noreply@github.com (the address
#     GitHub itself commits as). That committer address leaks nothing, but
#     it never excuses the author email: anyone can set it locally;
#   - no commit-supplied date decides anything: dates are forgeable
#     (GIT_COMMITTER_DATE), so the record carries no date and a commit
#     dated before the rule gets no exemption. Old history stays out of
#     the check through the range (PR base..head, push before..after);
#   - commit_email_evaluate reads one tab-separated record per line
#     (`<sha>\t<author name>\t<author email>\t<committer name>\t
#     <committer email>`), lists every offending commit with sha, author
#     and emails plus the fix command, and exits 1; all clean exits 0;
#   - commit_email_range picks the commit range from the event data;
#   - the record format fed through a real `git log` round-trips, and a
#     forged old committer date or a forged noreply@github.com committer
#     does not let a plain author email through;
#   - the library is pure: no GitHub API call, no `set`, nothing on stdout
#     at source time.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    # shellcheck source=../../lib/commit_email.sh
    source "${LIB_DIR}/commit_email.sh"
    NR='12345+someone@users.noreply.github.com'
    PLAIN='someone@example.com'
    WEB='noreply@github.com'
    ZERO='0000000000000000000000000000000000000000'
}

# Print one commit record: $1 sha, $2 author email, $3 committer email
# (names are fixed).
_rec() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" 'Some One' "$2" 'Some One' "$3"
}

# Commit in repo $1 with author email $2, committer email $3, committer
# date $4 and message $5.
_commit() {
    GIT_AUTHOR_NAME='Some One' GIT_AUTHOR_EMAIL="$2" \
        GIT_COMMITTER_NAME='Some One' GIT_COMMITTER_EMAIL="$3" \
        GIT_AUTHOR_DATE="$4" GIT_COMMITTER_DATE="$4" \
        git -C "$1" commit -q --allow-empty -m "$5"
}

# Run the CI record pipeline over repo $1, revision range $2.
_log_evaluate() {
    run bash -c 'source "$1"; git -C "$2" log --format="$(commit_email_log_format)" "$3" | commit_email_evaluate' \
        _ "${LIB_DIR}/commit_email.sh" "$1" "$2"
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

@test "the record format carries no date (no commit-supplied date decides anything)" {
    run commit_email_log_format
    assert_success
    assert_output '%H%x09%an%x09%ae%x09%cn%x09%ce'
}

@test "there is no date cutoff to exempt commits" {
    run grep -nE 'cutoff|%cd|%ad|[0-9]{4}-[0-9]{2}-[0-9]{2}T' "${LIB_DIR}/commit_email.sh"
    assert_failure
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

@test "author and committer both noreply pass" {
    run commit_email_commit_ok "${NR}" "${NR}"
    assert_success
}

@test "a plain author email fails" {
    run commit_email_commit_ok "${PLAIN}" "${NR}"
    assert_failure
}

@test "a plain committer email fails" {
    run commit_email_commit_ok "${NR}" "${PLAIN}"
    assert_failure
}

@test "committer noreply@github.com passes with a noreply author" {
    run commit_email_commit_ok "${NR}" "${WEB}"
    assert_success
}

@test "committer noreply@github.com does not excuse a plain author email" {
    run commit_email_commit_ok "${PLAIN}" "${WEB}"
    assert_failure
    run commit_email_commit_ok '' "${WEB}"
    assert_failure
}

@test "noreply@github.com is not accepted as an author email" {
    run commit_email_commit_ok "${WEB}" "${WEB}"
    assert_failure
}

@test "a date passed where an email belongs fails (no date argument)" {
    local _d
    for _d in '2025-99-99T99:99:99Z' '2026-99-99T99:99:99Z' '2026-09-29T23:59:59Z'; do
        run commit_email_commit_ok "${_d}" "${NR}"
        assert_failure
        run commit_email_commit_ok "${NR}" "${_d}"
        assert_failure
    done
}

# --- commit_email_evaluate -----------------------------------------------------

@test "evaluate: no commit passes" {
    run commit_email_evaluate < /dev/null
    assert_success
}

@test "evaluate: every commit clean passes" {
    run commit_email_evaluate < <(_rec aaa1 "${NR}" "${NR}"; _rec bbb2 "${NR}" "${WEB}")
    assert_success
    refute_output --partial 'aaa1'
    refute_output --partial 'bbb2'
}

@test "evaluate: an offending commit fails and is listed with sha, author and emails" {
    run commit_email_evaluate < <(_rec aaa1 "${NR}" "${NR}"; _rec bbb2 "${PLAIN}" "${NR}")
    assert_failure 1
    assert_output --partial 'bbb2'
    assert_output --partial 'Some One'
    assert_output --partial "${PLAIN}"
    refute_output --partial 'aaa1'
}

@test "evaluate: every offending commit is listed, not only the first" {
    run commit_email_evaluate < <(_rec ccc1 "${PLAIN}" "${NR}"; _rec ddd2 "${NR}" "${PLAIN}")
    assert_failure 1
    assert_output --partial 'ccc1'
    assert_output --partial 'ddd2'
}

@test "evaluate: the failure names the fix command" {
    run commit_email_evaluate < <(_rec bbb2 "${PLAIN}" "${PLAIN}")
    assert_failure 1
    assert_output --partial 'users.noreply.github.com'
    assert_output --partial 'git commit --amend --no-edit --reset-author'
    assert_output --partial 'git push --force-with-lease'
}

@test "evaluate: the last record may lack its newline" {
    run commit_email_evaluate < <(printf '%s\t%s\t%s\t%s\t%s' eee5 'A' "${PLAIN}" 'A' "${NR}")
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
    # Old history with a plain email stays out of the check via the range.
    _commit "${_repo}" "${PLAIN}" "${PLAIN}" '2026-09-01T10:00:00+08:00' base
    _base="$(git -C "${_repo}" rev-parse HEAD)"
    _commit "${_repo}" "${NR}" "${NR}" '2026-10-01T10:00:00+08:00' good
    _commit "${_repo}" "${NR}" "${WEB}" '2026-10-01T10:30:00+08:00' web
    _log_evaluate "${_repo}" "${_base}..HEAD"
    assert_success
    assert_output --partial '2 commits checked'
    _commit "${_repo}" "${PLAIN}" "${NR}" '2026-10-01T11:00:00+08:00' bad
    _log_evaluate "${_repo}" "${_base}..HEAD"
    assert_failure 1
    assert_output --partial "$(git -C "${_repo}" rev-parse HEAD)"
    refute_output --partial "$(git -C "${_repo}" rev-parse HEAD~1)"
}

@test "a forged old committer date does not excuse a plain email in the range" {
    local _repo="${BATS_TEST_TMPDIR}/repo" _base
    git init -q "${_repo}"
    _commit "${_repo}" "${NR}" "${NR}" '2026-10-01T10:00:00Z' base
    _base="$(git -C "${_repo}" rev-parse HEAD)"
    _commit "${_repo}" "${PLAIN}" "${PLAIN}" '2026-09-29T23:59:59Z' forged
    _log_evaluate "${_repo}" "${_base}..HEAD"
    assert_failure 1
    assert_output --partial "$(git -C "${_repo}" rev-parse HEAD)"
}

@test "a forged noreply@github.com committer does not excuse a plain author" {
    local _repo="${BATS_TEST_TMPDIR}/repo" _base
    git init -q "${_repo}"
    _commit "${_repo}" "${NR}" "${NR}" '2026-10-01T10:00:00Z' base
    _base="$(git -C "${_repo}" rev-parse HEAD)"
    _commit "${_repo}" "${PLAIN}" "${WEB}" '2026-10-01T11:00:00Z' forged
    _log_evaluate "${_repo}" "${_base}..HEAD"
    assert_failure 1
    assert_output --partial "$(git -C "${_repo}" rev-parse HEAD)"
    assert_output --partial "${PLAIN}"
}
