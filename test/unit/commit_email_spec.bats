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
#     every line it prints is a diagnostic, so all of it goes to stderr
#     and stdout stays empty (stdout is kept for data);
#   - commit_email_range validates the inputs the event uses (pull_request:
#     base, head, default ref; push: before, after, default ref), ignores
#     the other event's two fields, and fails closed on a missing, empty or
#     malformed used value (sha = 40 lowercase hex; default ref checked by
#     `git check-ref-format`); only a 40-zero `before` means a new ref, which
#     checks every commit reachable from `after` that is not on the default
#     branch. An input-state matrix pins the failures, and real git repos
#     pin the exact set of checked commits (1, many, merge, force-push
#     rewrite, new ref);
#   - the record format fed through a real `git log` round-trips, and a
#     forged old committer date or a forged noreply@github.com committer
#     does not let a plain author email through;
#   - the library is pure: no GitHub API call, no `set`, nothing on stdout
#     at source time.

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

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

# Run commit_email_evaluate keeping only its stderr (stdout is dropped), so
# `run` captures what the job log shows as diagnostics.
_evaluate_stderr_only() {
    { commit_email_evaluate >/dev/null; } 2>&1
}

@test "evaluate: a failure writes nothing to stdout" {
    run --separate-stderr commit_email_evaluate < <(_rec aaa1 "${NR}" "${NR}"; _rec bbb2 "${PLAIN}" "${NR}")
    assert_failure 1
    assert_output ''
}

@test "evaluate: a failure writes every diagnostic to stderr" {
    run _evaluate_stderr_only < <(_rec aaa1 "${NR}" "${NR}"; _rec bbb2 "${PLAIN}" "${NR}")
    assert_failure 1
    assert_output --partial 'bbb2'
    assert_output --partial "${PLAIN}"
    assert_output --partial '1 of 2 commits'
    assert_output --partial 'git commit --amend --no-edit --reset-author'
    assert_output --partial 'git push --force-with-lease'
}

@test "evaluate: a pass writes nothing to stdout and its summary to stderr" {
    run --separate-stderr commit_email_evaluate < <(_rec aaa1 "${NR}" "${NR}")
    assert_success
    assert_output ''
    run _evaluate_stderr_only < <(_rec aaa1 "${NR}" "${NR}")
    assert_success
    assert_output --partial '1 commits checked'
}

@test "evaluate: the last record may lack its newline" {
    run commit_email_evaluate < <(printf '%s\t%s\t%s\t%s\t%s' eee5 'A' "${PLAIN}" 'A' "${NR}")
    assert_failure 1
    assert_output --partial 'eee5'
}

# --- commit_email_range: input-state matrix --------------------------------
#
# The inputs the event uses are validated: pull_request -> base, head and
# the default ref; push -> before, after and the default ref. The other
# event's two fields are ignored whatever their value. A missing, empty or
# malformed used input fails closed (exit 1, a message on stderr, nothing
# on stdout) instead of falling back to a default. A sha is exactly 40
# lowercase hex (GitHub repos are SHA-1); the default ref must pass
# `git check-ref-format`. Only a 40-zero `before` means a new ref, and a
# new ref checks every commit reachable from `after` that is not on the
# default branch.

# Two distinct well-formed shas (values only; no repo needed).
SHA_A='1111111111111111111111111111111111111111'
SHA_B='2222222222222222222222222222222222222222'
DEF='refs/remotes/origin/main'

# Run commit_email_range keeping only its stderr (stdout is dropped).
_range_stderr_only() {
    { commit_email_range "$@" >/dev/null; } 2>&1
}

# Assert that commit_email_range fails closed for the given arguments:
# status 1, nothing on stdout, a message naming the range on stderr.
_range_fails() {
    run --separate-stderr commit_email_range "$@"
    assert_failure 1
    assert_output ''
    run _range_stderr_only "$@"
    assert_failure 1
    assert_output --partial 'commit_email_range:'
}

@test "range: a missing argument (fewer or more than six) fails closed" {
    _range_fails
    _range_fails push
    _range_fails push '' '' "${SHA_A}" "${SHA_B}"
    _range_fails pull_request "${SHA_A}" "${SHA_B}" '' ''
    _range_fails push '' '' "${SHA_A}" "${SHA_B}" "${DEF}" extra
}

@test "range: an unknown, empty or miscased event fails closed" {
    local _ev
    for _ev in '' workflow_dispatch Push PUSH pull_request_target 'push ' merge_group; do
        _range_fails "${_ev}" "${SHA_A}" "${SHA_B}" "${SHA_A}" "${SHA_B}" "${DEF}"
    done
}

# Values that are never a usable commit sha.
# States: empty, 39 and 41 hex, uppercase, non-hex, 64 hex and 64 zeros
# (SHA-256 forms: not accepted, GitHub repos are SHA-1), and rev syntax.
_MALFORMED=('' 'abc' '111111111111111111111111111111111111111' '11111111111111111111111111111111111111111'
    'gggggggggggggggggggggggggggggggggggggggg' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    '0000000000000000000000000000000000000000000000000000000000000000'
    'HEAD' 'main' '-n' "${SHA_A} " "${SHA_A}..${SHA_B}" "${SHA_A}^!")

@test "range: push with before missing, empty or malformed fails closed (no new-ref fallback)" {
    local _b
    for _b in "${_MALFORMED[@]}"; do
        _range_fails push '' '' "${_b}" "${SHA_B}" "${DEF}"
    done
}

@test "range: push with after missing, empty, all-zero or malformed fails closed" {
    local _a
    for _a in "${_MALFORMED[@]}" "${ZERO}"; do
        _range_fails push '' '' "${SHA_A}" "${_a}" "${DEF}"
        _range_fails push '' '' "${ZERO}" "${_a}" "${DEF}"
    done
}

@test "range: pull_request with base or head missing, empty, all-zero or malformed fails closed" {
    local _v
    for _v in "${_MALFORMED[@]}" "${ZERO}"; do
        _range_fails pull_request "${_v}" "${SHA_B}" '' '' "${DEF}"
        _range_fails pull_request "${SHA_A}" "${_v}" '' '' "${DEF}"
    done
}

# Default refs `git check-ref-format` rejects (plus missing/empty).
_BAD_REFS=('' 'main' 'refs/remotes/origin/' '/main' '-main' '--normalize' 'refs/remotes/origin/main.'
    'refs/remotes/origin/main.lock' 'refs/remotes/origin/a..b' 'refs/remotes/origin/a b'
    'refs/remotes/origin/main^' 'refs/remotes/origin/main~1' 'refs/remotes//origin/main')

@test "range: push with the default ref missing, empty or malformed fails closed" {
    local _d
    for _d in "${_BAD_REFS[@]}"; do
        _range_fails push '' '' "${ZERO}" "${SHA_B}" "${_d}"
        _range_fails push '' '' "${SHA_A}" "${SHA_B}" "${_d}"
    done
}

@test "range: pull_request with the default ref missing, empty or malformed fails closed" {
    local _d
    for _d in "${_BAD_REFS[@]}"; do
        _range_fails pull_request "${SHA_A}" "${SHA_B}" '' '' "${_d}"
    done
}

@test "range: pull_request ignores before and after whatever their value" {
    local _v
    for _v in '' 'garbage' "${ZERO}" '-n' 'x y'; do
        run --separate-stderr commit_email_range pull_request "${SHA_A}" "${SHA_B}" "${_v}" "${_v}" "${DEF}"
        assert_success
        assert_output "${SHA_A}..${SHA_B}"
    done
}

@test "range: push ignores the PR base and head whatever their value" {
    local _v
    for _v in '' 'garbage' "${ZERO}" '-n' 'x y'; do
        run --separate-stderr commit_email_range push "${_v}" "${_v}" "${SHA_A}" "${SHA_B}" "${DEF}"
        assert_success
        assert_output "${SHA_A}..${SHA_B}"
    done
}

@test "range: pull_request prints base..head" {
    run --separate-stderr commit_email_range pull_request "${SHA_A}" "${SHA_B}" '' '' "${DEF}"
    assert_success
    assert_output "${SHA_A}..${SHA_B}"
    # A synchronize event carries before/after too; they do not change the range.
    run --separate-stderr commit_email_range pull_request "${SHA_A}" "${SHA_B}" "${SHA_B}" "${SHA_A}" "${DEF}"
    assert_success
    assert_output "${SHA_A}..${SHA_B}"
}

@test "range: push with a valid before prints before..after" {
    run --separate-stderr commit_email_range push '' '' "${SHA_A}" "${SHA_B}" "${DEF}"
    assert_success
    assert_output "${SHA_A}..${SHA_B}"
}

@test "range: push of a new ref (all-zero before) prints after and ^default, not after^!" {
    run --separate-stderr commit_email_range push '' '' "${ZERO}" "${SHA_B}" "${DEF}"
    assert_success
    assert_equal "${#lines[@]}" 2
    assert_line --index 0 "${SHA_B}"
    assert_line --index 1 "^${DEF}"
    refute_output --partial '^!'
}

# --- commit_email_range: exact set of checked commits (real git) ------------

# Commit in repo $1 on the current branch with message $2 (noreply
# identity) and print the new sha.
_c() {
    GIT_AUTHOR_NAME='Some One' GIT_AUTHOR_EMAIL="${NR}" \
        GIT_COMMITTER_NAME='Some One' GIT_COMMITTER_EMAIL="${NR}" \
        git -C "$1" commit -q --allow-empty -m "$2"
    git -C "$1" rev-parse HEAD
}

# Print, sorted, the shas `git log` checks for the range computed from the
# event data $2..$7 in repo $1 (the CI wiring: one revision per line, fed
# to git log as separate arguments).
_checked() {
    local _repo="$1" _out _revs
    shift
    _out="$(commit_email_range "$@")" || return 1
    mapfile -t _revs <<< "${_out}"
    git -C "${_repo}" log --format=%H "${_revs[@]}" -- | sort
}

# Print the given shas sorted, one per line.
_set() { printf '%s\n' "$@" | sort; }

# A repo with main at one base commit, mirrored as refs/remotes/origin/main.
_repo_with_main() {
    local _repo="$1"
    git init -q -b main "${_repo}"
    _c "${_repo}" base > /dev/null
    git -C "${_repo}" update-ref refs/remotes/origin/main HEAD
}

@test "checked set: push of one commit is exactly that commit" {
    local _r="${BATS_TEST_TMPDIR}/r" _b _c1
    _repo_with_main "${_r}"
    _b="$(git -C "${_r}" rev-parse HEAD)"
    _c1="$(_c "${_r}" one)"
    run _checked "${_r}" push '' '' "${_b}" "${_c1}" "${DEF}"
    assert_success
    assert_output "$(_set "${_c1}")"
}

@test "checked set: push of many commits is every one of them, not only the tip" {
    local _r="${BATS_TEST_TMPDIR}/r" _b _c1 _c2 _c3
    _repo_with_main "${_r}"
    _b="$(git -C "${_r}" rev-parse HEAD)"
    _c1="$(_c "${_r}" one)"; _c2="$(_c "${_r}" two)"; _c3="$(_c "${_r}" three)"
    run _checked "${_r}" push '' '' "${_b}" "${_c3}" "${DEF}"
    assert_success
    assert_output "$(_set "${_c1}" "${_c2}" "${_c3}")"
}

@test "checked set: push with a merge commit covers the merge and both merged-in commits" {
    local _r="${BATS_TEST_TMPDIR}/r" _b _f1 _f2 _m1 _mg
    _repo_with_main "${_r}"
    _b="$(git -C "${_r}" rev-parse HEAD)"
    git -C "${_r}" checkout -q -b feat
    _f1="$(_c "${_r}" f1)"; _f2="$(_c "${_r}" f2)"
    git -C "${_r}" checkout -q main
    _m1="$(_c "${_r}" m1)"
    GIT_AUTHOR_NAME='Some One' GIT_AUTHOR_EMAIL="${NR}" \
        GIT_COMMITTER_NAME='Some One' GIT_COMMITTER_EMAIL="${NR}" \
        git -C "${_r}" merge -q --no-ff --no-edit feat
    _mg="$(git -C "${_r}" rev-parse HEAD)"
    run _checked "${_r}" push '' '' "${_b}" "${_mg}" "${DEF}"
    assert_success
    assert_output "$(_set "${_f1}" "${_f2}" "${_m1}" "${_mg}")"
}

@test "checked set: a force-push rewrite checks every rewritten commit, not the dropped ones" {
    local _r="${BATS_TEST_TMPDIR}/r" _b _o1 _o2 _n1 _n2
    _repo_with_main "${_r}"
    _b="$(git -C "${_r}" rev-parse HEAD)"
    _o1="$(_c "${_r}" old1)"; _o2="$(_c "${_r}" old2)"
    git -C "${_r}" reset -q --hard "${_b}"
    _n1="$(_c "${_r}" new1)"; _n2="$(_c "${_r}" new2)"
    run _checked "${_r}" push '' '' "${_o2}" "${_n2}" "${DEF}"
    assert_success
    assert_output "$(_set "${_n1}" "${_n2}")"
    refute_output --partial "${_o1}"
}

@test "checked set: a new ref checks every commit not on the default branch (1, many, merge)" {
    local _r="${BATS_TEST_TMPDIR}/r" _f1 _f2 _f3 _s1 _mg
    _repo_with_main "${_r}"
    git -C "${_r}" checkout -q -b feat
    _f1="$(_c "${_r}" f1)"
    run _checked "${_r}" push '' '' "${ZERO}" "${_f1}" "${DEF}"
    assert_success
    assert_output "$(_set "${_f1}")"
    _f2="$(_c "${_r}" f2)"; _f3="$(_c "${_r}" f3)"
    run _checked "${_r}" push '' '' "${ZERO}" "${_f3}" "${DEF}"
    assert_success
    assert_output "$(_set "${_f1}" "${_f2}" "${_f3}")"
    git -C "${_r}" checkout -q -b side main
    _s1="$(_c "${_r}" s1)"
    git -C "${_r}" checkout -q feat
    GIT_AUTHOR_NAME='Some One' GIT_AUTHOR_EMAIL="${NR}" \
        GIT_COMMITTER_NAME='Some One' GIT_COMMITTER_EMAIL="${NR}" \
        git -C "${_r}" merge -q --no-ff --no-edit side
    _mg="$(git -C "${_r}" rev-parse HEAD)"
    run _checked "${_r}" push '' '' "${ZERO}" "${_mg}" "${DEF}"
    assert_success
    assert_output "$(_set "${_f1}" "${_f2}" "${_f3}" "${_s1}" "${_mg}")"
}

@test "checked set: pull_request covers every commit of base..head including a merge" {
    local _r="${BATS_TEST_TMPDIR}/r" _b _f1 _s1 _mg
    _repo_with_main "${_r}"
    _b="$(git -C "${_r}" rev-parse HEAD)"
    git -C "${_r}" checkout -q -b side
    _s1="$(_c "${_r}" s1)"
    git -C "${_r}" checkout -q -b feat main
    _f1="$(_c "${_r}" f1)"
    GIT_AUTHOR_NAME='Some One' GIT_AUTHOR_EMAIL="${NR}" \
        GIT_COMMITTER_NAME='Some One' GIT_COMMITTER_EMAIL="${NR}" \
        git -C "${_r}" merge -q --no-ff --no-edit side
    _mg="$(git -C "${_r}" rev-parse HEAD)"
    run _checked "${_r}" pull_request "${_b}" "${_mg}" '' '' "${DEF}"
    assert_success
    assert_output "$(_set "${_f1}" "${_s1}" "${_mg}")"
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
