#!/usr/bin/env bash
# .agents/script/watch-user-replies.sh - poll a GitHub repo's OPEN issues
# and PRs and print the maintainer's own comments that are NOT agent output.
#
# It answers "has the human replied to me?" and is meant to be wrapped in a
# single Monitor call: the poll loop lives here, so the Monitor emits an
# event only when a genuine reply appears.
#
# Division of labour:
#   - watch_reply_is_user, watch_replies_filter and watch_default_state_file
#     are PURE (no network): the specs source this file and call them.
#   - main parses the command line, then seeds or runs the fetch loop.
#
# What counts as a user reply: a comment authored by --login whose body does
# NOT START with an agent tag ([claude] or [codex]). The tag is matched at
# the START only; matching it anywhere once swallowed a real acceptance
# report that merely quoted "[codex]" in its prose (see
# test/unit/script/watch_user_replies_spec.bats, "quoting an agent tag").
#
# State: the ids already announced, one per line. By default it lives in
# this repo, in the gitignored .agents/state/ (WORKTOOL_AGENT_STATE_DIR
# overrides the directory), one file per repo + login - so a restart never
# re-announces old replies. --state-file picks any other file.
#
# CLI contract (worktool): the whole command line is parsed before --help
# is served; `watch-user-replies.sh: <problem> (see --help)` on stderr +
# exit 2 for any argument error; usage on stderr.
#
# Exit: 0 normal (a cycle completed, --help, --seed; a failed list or fetch
# in the loop is reported as a WATCH FETCH FAILED event, not an exit code),
# 1 --seed could not list or read every thread (nothing seeded), 2 argument
# error.
#
# Output: STDOUT carries only events worth acting on, one per line:
#   USER REPLY on #<n> : <first 200 chars of the body, newlines folded>
#   WATCH FETCH FAILED: <failed> of <total> thread(s) unreadable this cycle
#   WATCH FETCH FAILED: could not list the open issues/PRs this cycle
# Heartbeats and fetch warnings go to STDERR.
#
# Strict mode (doc/adr/0001-scripts-use-errexit.md, issue #218): every
# expected non-zero - a failed list or fetch, grep finding no id, a body
# that is not valid base64 - is handled explicitly. A help request travels
# in W_HELP, so _parse_args returns 0 and is called directly.

set -euo pipefail

AGENT_TAGS=('[claude]' '[codex]')

# Set by main; the EXIT trap quotes it lazily so no SC2064 disable is needed.
WATCH_TMP=''

# watch_reply_is_user <login> <comment-login> <body>
#   0 = this comment is a human reply, 1 = it is agent output or someone else.
watch_reply_is_user() {
    local _want="$1" _got="$2" _body="$3" _tag
    [[ "${_got}" == "${_want}" ]] || return 1
    for _tag in "${AGENT_TAGS[@]}"; do
        # Anchored at the start on purpose; see the header note.
        [[ "${_body}" == "${_tag}"* ]] && return 1
    done
    return 0
}

# watch_replies_filter <login> <state-file> <tsv-file>
#   tsv-file lines: <issue-number>\t<comment-id>\t<comment-login>\t<body-base64>
#   Prints one event line per UNSEEN human reply and appends its id to the
#   state file. Base64 keeps multi-line bodies on a single TSV line.
watch_replies_filter() {
    local _login="$1" _state="$2" _tsv="$3"
    local _num _id _author _b64 _body _preview
    [[ -f "${_state}" ]] || : > "${_state}"
    while IFS=$'\t' read -r _num _id _author _b64; do
        [[ -n "${_id}" ]] || continue
        # Undecodable: say so and keep what did decode (it may be a reply).
        if ! _body="$(printf '%s' "${_b64}" | base64 -d 2>/dev/null)"; then
            printf '[watch] comment %s body is not valid base64\n' "${_id}" >&2
        fi
        watch_reply_is_user "${_login}" "${_author}" "${_body}" || continue
        grep -qxF "${_id}" "${_state}" && continue
        printf '%s\n' "${_id}" >> "${_state}"
        _preview="$(printf '%s' "${_body}" | tr '\n\r\t' '   ' | cut -c1-200)"
        printf 'USER REPLY on #%s : %s\n' "${_num}" "${_preview}"
    done < "${_tsv}"
}

# The repo this script lives in (.agents/script -> two levels up).
WATCH_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# watch_default_state_file <repo> <login> - the default state file: one per
# repo + login under ${WORKTOOL_AGENT_STATE_DIR:-<repo>/.agents/state}.
watch_default_state_file() {
    local _dir="${WORKTOOL_AGENT_STATE_DIR:-${WATCH_REPO_ROOT}/.agents/state}"
    printf '%s/watch-user-replies-%s-%s.seen\n' "${_dir}" "${1//\//_}" "$2"
}

_usage() {
    cat >&2 <<'EOF'
Usage: watch-user-replies.sh --repo <OWNER>/<REPO> --login <USER> [options]

Poll the repo's open issues and PRs and print each new comment by <USER>
that does not start with an agent tag ([claude] / [codex]):
  USER REPLY on #<n> : <first 200 chars>

Options:
  --repo <OWNER>/<REPO>  GitHub repo (required)
  --login <USER>         comment author to watch for (required)
  --interval <seconds>   poll interval, a positive integer (default 180)
  --state-file <path>    file of already-seen comment ids, one per line
                         (default: .agents/state/watch-user-replies-
                         <owner>_<repo>-<login>.seen in this repo, or under
                         $WORKTOOL_AGENT_STATE_DIR)
  --seed                 mark every current reply as seen WITHOUT printing,
                         then exit (arm a fresh watch on a repo with history)
  --once                 one check-and-print, then exit
  -h, --help             show this help and exit

Exit: 0 normal, 1 --seed could not list or read every thread, 2 argument error.
EOF
}

_die_args() {
    printf 'watch-user-replies.sh: %s (see --help)\n' "$1" >&2
    exit 2
}

# _list_numbers <repo> - the numbers of every OPEN issue and PR, one per
# line. Both list calls run in THIS shell (not a process substitution) so
# their exit codes are seen; gh's own error stays on stderr. Returns 1 when
# either call failed (what the other one listed is still printed).
_list_numbers() {
    local _repo="$1" _issues _prs _rc=0
    _issues="$(gh issue list --repo "${_repo}" --state open --limit 1000 \
        --json number --jq '.[].number')" || _rc=1
    _prs="$(gh pr list --repo "${_repo}" --state open --limit 1000 \
        --json number --jq '.[].number')" || _rc=1
    [[ "${_rc}" -eq 0 ]] \
        || printf '[watch] listing the open issues/PRs failed, see above\n' >&2
    printf '%s\n%s\n' "${_issues}" "${_prs}"
    return "${_rc}"
}

# _fetch <repo> <out-tsv>
#   Appends one TSV line per comment on every OPEN issue and PR, every page
#   of them (gh api --paginate). A failure on any single number warns and is
#   skipped: a transient error must not look like "no replies". Prints
#   "<failed> <total> <list-failed>" on stdout so the caller can surface a
#   failed cycle instead of treating it as silence; <list-failed> is 1 when
#   the issue or PR list itself could not be read.
#
#   The issue number is spliced into the jq program as a string literal.
#   `gh api` has no --arg flag (only standalone jq does); passing one made
#   every fetch fail with "unknown flag: --arg". _n is digits-only (checked
#   below), so splicing it cannot inject jq.
_fetch() {
    local _repo="$1" _out="$2" _n _failed=0 _total=0 _list_failed=0 _listed
    local _nums=()
    _listed="$(_list_numbers "${_repo}")" || _list_failed=1
    mapfile -t _nums <<<"${_listed}"
    : > "${_out}"
    for _n in "${_nums[@]:-}"; do
        [[ "${_n}" =~ ^[0-9]+$ ]] || continue
        _total=$((_total + 1))
        if ! gh api --paginate "repos/${_repo}/issues/${_n}/comments?per_page=100" \
            --jq ".[] | [\"${_n}\", (.id|tostring), .user.login, (.body|@base64)] | @tsv" \
            >> "${_out}" 2>/dev/null; then
            _failed=$((_failed + 1))
            printf '[watch] fetch failed for #%s, skipping this cycle\n' \
                "${_n}" >&2
        fi
    done
    printf '%s %s %s\n' "${_failed}" "${_total}" "${_list_failed}"
}

# Settings (filled by _parse_args).
W_REPO=''
W_LOGIN=''
W_INTERVAL=180
W_STATE=''
W_ONCE=0
W_SEED=0
W_HELP=0

# _parse_args "$@" - the whole command line before anything is served;
# sets W_HELP=1 when help was asked for and the line is otherwise valid.
_parse_args() {
    local _help=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo|--login|--interval|--state-file)
                [[ $# -ge 2 ]] || _die_args "$1 needs a value"
                case "$1" in
                    --repo) W_REPO="$2" ;;
                    --login) W_LOGIN="$2" ;;
                    --interval) W_INTERVAL="$2" ;;
                    --state-file) W_STATE="$2" ;;
                esac
                shift ;;
            --seed) W_SEED=1 ;;
            --once) W_ONCE=1 ;;
            -h|--help) _help=1 ;;
            *) _die_args "unknown option '$1'" ;;
        esac
        shift
    done
    if [[ "${_help}" -eq 1 ]]; then
        W_HELP=1
        return 0
    fi
    [[ -n "${W_REPO}" ]] || _die_args "--repo is required"
    [[ -n "${W_LOGIN}" ]] || _die_args "--login is required"
    [[ "${W_INTERVAL}" =~ ^[1-9][0-9]*$ ]] \
        || _die_args "--interval must be a positive integer"
    return 0
}

# _seed <tmp> - mark every current reply as seen without announcing; refuse
# a partial seed (it would re-announce the unread threads' history later).
_seed() {
    local _failed _total _list_failed
    read -r _failed _total _list_failed < <(_fetch "${W_REPO}" "$1")
    if [[ "${_list_failed}" -ne 0 ]]; then
        printf '[watch] seed aborted: the open issues/PRs could not be listed\n' >&2
        return 1
    fi
    if [[ "${_failed}" -gt 0 ]]; then
        printf '[watch] seed aborted: %s of %s thread(s) unreadable\n' \
            "${_failed}" "${_total}" >&2
        return 1
    fi
    watch_replies_filter "${W_LOGIN}" "${W_STATE}" "$1" >/dev/null
    printf '[watch] seeded: %s id(s) marked seen, nothing announced\n' \
        "$(grep -c . "${W_STATE}")" >&2
    return 0
}

# _watch <tmp> - the poll loop (one cycle with --once).
_watch() {
    local _failed _total _list_failed
    while true; do
        read -r _failed _total _list_failed < <(_fetch "${W_REPO}" "$1")
        if [[ "${_list_failed}" -ne 0 ]]; then
            printf 'WATCH FETCH FAILED: could not list the open issues/PRs this cycle\n'
        fi
        if [[ "${_failed}" -gt 0 ]]; then
            # STDOUT on purpose: the Monitor only notifies on stdout, and a
            # silent failure is indistinguishable from "no replies".
            printf 'WATCH FETCH FAILED: %s of %s thread(s) unreadable this cycle\n' \
                "${_failed}" "${_total}"
        fi
        watch_replies_filter "${W_LOGIN}" "${W_STATE}" "$1"
        printf '[watch] heartbeat %s\n' "$(date -u +%H:%M:%SZ)" >&2
        [[ "${W_ONCE}" -eq 1 ]] && return 0
        sleep "${W_INTERVAL}"
    done
}

main() {
    _parse_args "$@"
    if [[ "${W_HELP}" -eq 1 ]]; then
        _usage
        exit 0
    fi
    [[ -n "${W_STATE}" ]] || W_STATE="$(watch_default_state_file "${W_REPO}" "${W_LOGIN}")"
    mkdir -p "$(dirname -- "${W_STATE}")" || exit 1
    [[ -f "${W_STATE}" ]] || : >"${W_STATE}" || exit 1

    WATCH_TMP="$(mktemp)" || exit 1
    trap 'rm -f "${WATCH_TMP}"' EXIT
    # Called directly so -e holds inside them; a refused seed returns 1,
    # and -e makes that the exit code (the documented 1).
    if [[ "${W_SEED}" -eq 1 ]]; then
        _seed "${WATCH_TMP}"
        exit 0
    fi
    _watch "${WATCH_TMP}"
    exit 0
}

# Only run main when executed, so the pure functions can be sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
