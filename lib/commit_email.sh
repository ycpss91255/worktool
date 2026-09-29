#!/usr/bin/env bash
# lib/commit_email.sh - noreply commit email predicate (issue #234).
#
# The repo is public, so every commit made from the cutoff on must carry a
# GitHub noreply address (`<id>+<login>@users.noreply.github.com`) as BOTH
# its author and its committer email. Rules:
#
#   - committer date before the cutoff (2026-09-30T00:00:00Z): allowed;
#     that history predates the rule and main is never rewritten;
#   - committer email `noreply@github.com` (web-flow: the merge button, web
#     edits): allowed; GitHub itself sets those emails;
#   - otherwise both emails must end with @users.noreply.github.com;
#   - a committer date that is not a UTC `YYYY-MM-DDTHH:MM:SSZ` stamp fails
#     (fail closed: an unreadable date never skips the check).
#
# The predicate is pure: it takes plain data and makes no GitHub API call;
# the CI job (.github/workflows/ci.yml, job commit-email) collects the
# records with `git log` and feeds them in.
#
# Public API:
#   commit_email_cutoff            -> prints the cutoff stamp.
#   commit_email_log_format        -> prints the `git log --format` that
#       yields one record; run it with
#       `TZ=UTC git log --date=format-local:%Y-%m-%dT%H:%M:%SZ`.
#   commit_email_is_noreply <email> -> 0 when <email> is a noreply address.
#   commit_email_commit_ok <date> <author_email> <committer_email>
#       -> 0 when that one commit satisfies the rule, 1 otherwise.
#   commit_email_range <event> <pr_base> <pr_head> <push_before> <push_after>
#       -> prints the `git log` revision range to check; 1 on missing data
#       or an event other than pull_request / push.
#   commit_email_evaluate          (records on stdin)
#       stdin: one record per line, `<sha>\t<committer date>\t<author name>
#       \t<author email>\t<committer name>\t<committer email>` (the last
#       newline may be missing).
#       -> exit 0 = every commit passes, 1 = at least one fails; stdout
#       lists every offending commit and the fix command.
#
# This is a library: it defines functions and must be sourced, not
# executed. It sets no shell options and prints nothing at source time.

commit_email_cutoff() {
    printf '%s\n' '2026-09-30T00:00:00Z'
}

commit_email_log_format() {
    printf '%s\n' '%H%x09%cd%x09%an%x09%ae%x09%cn%x09%ce'
}

commit_email_is_noreply() {
    local _email="$1" _suffix='@users.noreply.github.com'
    [[ "${_email}" == ?*"${_suffix}" ]] || return 1
    # Exactly one `@`: the local part is `<id>+<login>` or `<login>`.
    [[ "${_email%"${_suffix}"}" != *@* ]]
}

commit_email_commit_ok() {
    local _date="$1" _author="$2" _committer="$3"
    local _stamp='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    [[ "${_date}" =~ ${_stamp} ]] || return 1
    # Same fixed-width UTC format on both sides, so string order is time order.
    [[ "${_date}" < "$(commit_email_cutoff)" ]] && return 0
    [[ "${_committer}" == 'noreply@github.com' ]] && return 0
    commit_email_is_noreply "${_author}" && commit_email_is_noreply "${_committer}"
}

commit_email_range() {
    local _event="$1" _base="$2" _head="$3" _before="$4" _after="$5"
    case "${_event}" in
        pull_request)
            [[ -n "${_base}" && -n "${_head}" ]] || return 1
            printf '%s\n' "${_base}..${_head}"
            ;;
        push)
            [[ -n "${_after}" ]] || return 1
            if [[ -z "${_before}" || "${_before}" =~ ^0+$ ]]; then
                printf '%s\n' "${_after}^!"
            else
                printf '%s\n' "${_before}..${_after}"
            fi
            ;;
        *) return 1 ;;
    esac
}

# Print the fix instructions for offending commits.
_commit_email_fix() {
    printf '%s\n' \
        '' \
        'Fix: set the noreply address, rewrite the PR branch, push it again:' \
        '  git config user.email "<id>+<login>@users.noreply.github.com"' \
        "  git rebase -r --exec 'git commit --amend --no-edit --reset-author' origin/main" \
        '  git push --force-with-lease' \
        'A single last commit: git commit --amend --no-edit --reset-author'
}

commit_email_evaluate() {
    local _sha _date _an _ae _cn _ce _bad=0 _n=0
    while IFS=$'\t' read -r _sha _date _an _ae _cn _ce || [[ -n "${_sha}" ]]; do
        _n=$((_n + 1))
        if ! commit_email_commit_ok "${_date}" "${_ae}" "${_ce}"; then
            _bad=$((_bad + 1))
            printf '%s author %s <%s> committer %s <%s> (%s)\n' \
                "${_sha}" "${_an}" "${_ae}" "${_cn}" "${_ce}" "${_date}"
        fi
        _sha=''
    done
    if ((_bad > 0)); then
        printf '%s of %s commits need a @users.noreply.github.com author and committer email (from %s on).\n' \
            "${_bad}" "${_n}" "$(commit_email_cutoff)"
        _commit_email_fix
        return 1
    fi
    printf '%s commits checked: author and committer email ok.\n' "${_n}"
}
