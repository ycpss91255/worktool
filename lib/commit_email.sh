#!/usr/bin/env bash
# lib/commit_email.sh - noreply commit email predicate (issue #234).
#
# The repo is public, so every commit the CI checks must carry a GitHub
# noreply author email (`<id>+<login>@users.noreply.github.com`). Rules:
#
#   - the author email must be a noreply address, always;
#   - the committer email must be a noreply address too, or exactly
#     `noreply@github.com` (what GitHub commits as for the merge button and
#     web edits). That address leaks nothing, but it is set locally just as
#     easily, so it never excuses the author email;
#   - no date decides anything: a commit carries whatever date its maker
#     set (GIT_COMMITTER_DATE), so a date exemption would be a bypass. The
#     history made before the rule stays out of the check through the
#     revision range instead (PR base..head, push before..after, new ref
#     after ^default-branch). The range never guesses: a missing or
#     malformed input fails the check instead of shrinking the range.
#
# The predicate is pure: it takes plain data and makes no GitHub API call;
# the CI job (.github/workflows/ci.yml, job commit-email) collects the
# records with `git log` and feeds them in.
#
# Public API:
#   commit_email_log_format        -> prints the `git log --format` that
#       yields one record.
#   commit_email_is_noreply <email> -> 0 when <email> is a noreply address.
#   commit_email_commit_ok <author_email> <committer_email>
#       -> 0 when that one commit satisfies the rule, 1 otherwise.
#   commit_email_range <event> <pr_base> <pr_head> <push_before> <push_after>
#                      <default_ref>
#       -> prints the `git log` revisions to check, one per line (pass each
#       line as its own argument). Every input is validated and a missing,
#       empty or malformed one fails closed: exit 1, a message on stderr,
#       nothing on stdout; no value falls back to a default. Exactly six
#       arguments; <event> is `pull_request` or `push`; <default_ref> is a
#       plain ref name (e.g. refs/remotes/origin/main).
#         pull_request: <pr_base>..<pr_head>, both full non-zero shas.
#         push: <push_after> a full non-zero sha; <push_before> a full sha:
#           non-zero -> <push_before>..<push_after> (a force-push rewrite
#           checks every new commit); all zeros (a new ref, and only then)
#           -> <push_after> and ^<default_ref>: every commit reachable from
#           the pushed tip that is not on the default branch, not the tip
#           alone.
#   commit_email_evaluate          (records on stdin)
#       stdin: one record per line, `<sha>\t<author name>\t<author email>
#       \t<committer name>\t<committer email>` (the last newline may be
#       missing).
#       -> exit 0 = every commit passes, 1 = at least one fails. Every
#       line it prints is a diagnostic (each offending commit, the counts,
#       the fix command, the success summary), so it all goes to stderr
#       through lib/log.sh; stdout stays empty.
#
# This is a library: it defines functions and must be sourced, not
# executed. It sets no shell options and prints nothing at source time.
# It sources lib/log.sh (same dir) so callers get consistent diagnostics.

# --- Dependencies ------------------------------------------------------------
# `source=` below resolves against this file's own dir (lib/).
# shellcheck source-path=SCRIPTDIR
_COMMIT_EMAIL_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./log.sh
source "${_COMMIT_EMAIL_LIB_DIR}/log.sh"

commit_email_log_format() {
    printf '%s\n' '%H%x09%an%x09%ae%x09%cn%x09%ce'
}

commit_email_is_noreply() {
    local _email="$1" _suffix='@users.noreply.github.com'
    [[ "${_email}" == ?*"${_suffix}" ]] || return 1
    # Exactly one `@`: the local part is `<id>+<login>` or `<login>`.
    [[ "${_email%"${_suffix}"}" != *@* ]]
}

commit_email_commit_ok() {
    local _author="$1" _committer="$2"
    commit_email_is_noreply "${_author}" || return 1
    [[ "${_committer}" == 'noreply@github.com' ]] || commit_email_is_noreply "${_committer}"
}

# True when $1 is a full lowercase commit sha (40 hex for SHA-1, 64 for
# SHA-256) and nothing else.
_commit_email_is_sha() {
    [[ "$1" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]
}

# True when $1 is all zeros: GitHub's `before` for a newly created ref.
_commit_email_is_zero() {
    [[ "$1" =~ ^(0{40}|0{64})$ ]]
}

# True when $1 names a real commit: a full sha that is not all zeros.
_commit_email_is_commit() {
    _commit_email_is_sha "$1" && ! _commit_email_is_zero "$1"
}

# True when $1 is a plain ref name usable as `^<ref>`: slash-separated
# components of [A-Za-z0-9._-], none empty, none starting with `.` or `-`,
# and no `..` anywhere.
_commit_email_is_ref() {
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*$ && "$1" != *..* ]]
}

# Report one invalid range input on stderr (the caller then returns 1).
_commit_email_range_error() {
    log_error "commit_email_range: $1; refusing to guess a range (fail closed)."
}

commit_email_range() {
    if (($# != 6)); then
        _commit_email_range_error "expected 6 arguments (event, PR base, PR head, push before, push after, default ref), got $#"
        return 1
    fi
    local _event="$1" _base="$2" _head="$3" _before="$4" _after="$5" _default="$6"
    if ! _commit_email_is_ref "${_default}"; then
        _commit_email_range_error "default ref '${_default}' is not a ref name"
        return 1
    fi
    case "${_event}" in
        pull_request)
            if ! _commit_email_is_commit "${_base}"; then
                _commit_email_range_error "pull_request base '${_base}' is not a commit sha"
                return 1
            fi
            if ! _commit_email_is_commit "${_head}"; then
                _commit_email_range_error "pull_request head '${_head}' is not a commit sha"
                return 1
            fi
            printf '%s\n' "${_base}..${_head}"
            ;;
        push)
            if ! _commit_email_is_commit "${_after}"; then
                _commit_email_range_error "push after '${_after}' is not a commit sha"
                return 1
            fi
            if ! _commit_email_is_sha "${_before}"; then
                _commit_email_range_error "push before '${_before}' is not a commit sha (only all zeros means a new ref)"
                return 1
            fi
            if _commit_email_is_zero "${_before}"; then
                # New ref: every commit reachable from after that is not on
                # the default branch, not just the tip.
                printf '%s\n' "${_after}" "^${_default}"
            else
                printf '%s\n' "${_before}..${_after}"
            fi
            ;;
        *)
            _commit_email_range_error "event '${_event}' is neither pull_request nor push"
            return 1
            ;;
    esac
}

# Print the fix instructions for offending commits (stderr).
_commit_email_fix() {
    log_info 'Fix: set the noreply address, rewrite the PR branch, push it again:'
    log_info '  git config user.email "<id>+<login>@users.noreply.github.com"'
    log_info "  git rebase -r --exec 'git commit --amend --no-edit --reset-author' origin/main"
    log_info '  git push --force-with-lease'
    log_info 'A single last commit: git commit --amend --no-edit --reset-author'
}

commit_email_evaluate() {
    local _sha _an _ae _cn _ce _bad=0 _n=0
    while IFS=$'\t' read -r _sha _an _ae _cn _ce || [[ -n "${_sha}" ]]; do
        _n=$((_n + 1))
        if ! commit_email_commit_ok "${_ae}" "${_ce}"; then
            _bad=$((_bad + 1))
            log_error "${_sha} author ${_an} <${_ae}> committer ${_cn} <${_ce}>"
        fi
        _sha=''
    done
    if ((_bad > 0)); then
        log_error "${_bad} of ${_n} commits need a @users.noreply.github.com author and committer email."
        _commit_email_fix
        return 1
    fi
    log_info "${_n} commits checked: author and committer email ok."
}
