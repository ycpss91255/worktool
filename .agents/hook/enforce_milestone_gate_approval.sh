#!/usr/bin/env bash
# .agents/hook/enforce_milestone_gate_approval.sh - Claude Code PreToolUse
# hook (matcher: Bash), registered in .claude/settings.json (issue #190).
#
# The agent-side half of the milestone-gate approval (#187). GitHub cannot
# tell the maintainer from an agent posting with the maintainer's token, so
# this hook BLOCKS (exit 2, reason on stderr) what only an agent could do:
#   1. merge gate: `gh pr merge [<sel>]` (any flags, --auto included) and
#      `gh api .../repos/<owner>/<repo>/pulls/<n>/merge`. The repo comes from
#      -R / --repo, a PR URL or the api path, else `gh repo view`; a branch
#      or missing selector is resolved with `gh pr view`. The PR's labels
#      and comments are fetched with gh and handed to approval_evaluate of
#      lib/approval.sh (the same predicate the milestone-gate workflow
#      runs). A failed evaluation blocks, naming what is missing; ANY
#      failed lookup blocks too (fail closed).
#   2. anti-forgery: the body of `gh pr comment|review|create` and
#      `gh issue comment|create` (--body / -b, --body-file / -F read from
#      disk) and of `gh api` writes to .../comments (-f / -F / --raw-field /
#      --field body=..., body=@file, --input <json>) must not read as a
#      human approval by approval_is_human_approval. Every occurrence of a
#      repeated flag is judged, in every form (-b x, -bx, -b=x, --body=x),
#      and the last -X / --method decides a read. A body holding the
#      approval phrase must start with [claude] or [codex]. A body the hook
#      cannot read (stdin, a missing file, a command substitution, --input
#      included) blocks. A gh api endpoint (or other bare word) built by a
#      command substitution blocks unless the call only reads.
#   3. substitutions: a command substitution decodes to '_', so the hook
#      cannot know what it expands to. It blocks in any word of a
#      `gh pr merge` (selector, -R, flags), in a word naming the gh
#      sub-command (`gh pr "$(echo merge)"`), and, when UNQUOTED (the shell
#      word-splits it into words the hook never saw, -X PUT or --body
#      included), anywhere in a gh api or body-command launch.
# The approval rule and phrase live only in lib/approval.sh; this hook
# fetches data and never restates the rule. Only real gh launches count
# (lib/subcommand.sh; a leading timeout(1) with its options, valued ones
# included, is skipped by hook_timeout_lead): quoted text, commit messages
# and heredoc bodies that merely mention gh are data. Everything else
# passes silently, without calling gh.

# shellcheck source-path=SCRIPTDIR/lib
# Exit-code-contract hook: `set -uo pipefail`, NOT -e (a probe returning 1
# must not abort the decision); every gh lookup is still checked on its own,
# never through a pipe, so fail closed does not depend on pipefail.
set -uo pipefail

_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-milestone-gate-approval"
# shellcheck source=../../../lib/approval.sh
source "${HOOK_REPO_ROOT}/lib/approval.sh"

# The launch under judgement: decoded words (_W), encoded words (_E), the
# index of its sub-command word (_ARG0: `merge` of `gh pr [-R x] merge`)
# and the session's working directory from the payload (_CWD).
_W=()
_E=()
_ARG0=0
_CWD=''

# Flags taking a value, per command, so positionals can be told apart.
readonly _MERGE_VALUE_OPTS=' -R --repo -b --body -F --body-file -t --subject -A --author-email --match-head-commit '
readonly _API_VALUE_OPTS=' -X --method -f -F --field --raw-field -H --header --input -q --jq -t --template --hostname --cache -p --preview '

# _load_launch <encoded sub-command> - fill _W / _E from a gh launch (a
# leading timeout(1), its options and duration are skipped, by
# hook_timeout_lead of lib/subcommand.sh); fail when it is no gh.
_load_launch() {
    local _lead _i
    _lead="$(hook_timeout_lead "$1")"
    read -r -a _E <<<"${1#"${_lead}"}"
    [[ "${_E[0]:-}" == gh || "${_E[0]:-}" == */gh ]] || return 1
    _W=()
    for _i in "${!_E[@]}"; do _W[_i]="$(hook_word "${_E[_i]}")"; done
    _ARG0=2
    case "${_W[2]:-}" in
        -R|--repo) _ARG0=4 ;;
        --repo=*) _ARG0=3 ;;
    esac
    return 0
}

# _sub - the launch's "<group> <sub>" (e.g. "pr merge"), or "api".
_sub() {
    if [[ "${_W[1]:-}" == api ]]; then
        printf 'api'
    else
        printf '%s %s' "${_W[1]:-}" "${_W[_ARG0]:-}"
    fi
}

# _opt_at <name>... - print, one per line, where the value of EVERY
# occurrence of the given options sits: `<index>` (the next word) or
# `<index>:<offset>` (inside the word: --name=value, -nvalue, -n=value).
# gh keeps the last value of a repeated flag; a check reads them all.
_opt_at() {
    local _i _n _w _found=1
    for ((_i = 2; _i < ${#_W[@]}; _i++)); do
        _w="${_W[_i]}"
        for _n in "$@"; do
            if [[ "${_w}" == "${_n}" ]]; then
                printf '%s\n' "$((_i + 1))"; _i=$((_i + 1)); _found=0; break
            elif [[ "${_n}" == --* && "${_w}" == "${_n}="* ]]; then
                printf '%s:%s\n' "${_i}" "$((${#_n} + 1))"; _found=0; break
            elif [[ "${_n}" == -? && "${_w}" == "${_n}"?* ]]; then
                [[ "${_w}" == "${_n}="* ]] && printf '%s:3\n' "${_i}" || printf '%s:2\n' "${_i}"
                _found=0; break
            fi
        done
    done
    return "${_found}"
}

# _opt_word <at> - the decoded value at <at> (a line of _opt_at).
_opt_word() {
    if [[ "$1" == *:* ]]; then
        printf '%s' "${_W[${1%:*}]:${1#*:}}"
    else
        printf '%s' "${_W[$1]:-}"
    fi
}

# _opt <name>... - the decoded value of the LAST given option, as gh reads it.
_opt() {
    local _at
    _at="$(_opt_at "$@" | tail -n 1)"
    [[ -n "${_at}" ]] || return 1
    _opt_word "${_at}"
}

# _opt_values <name>... - every value of the given options, NUL-terminated.
_opt_values() {
    local _at
    while IFS= read -r _at; do
        printf '%s\0' "$(_opt_word "${_at}")"
    done < <(_opt_at "$@")
}

# _opt_has_subst <name>... - 0 when any value of those options holds a
# command substitution (the hook cannot know what it expands to).
_opt_has_subst() {
    local _at
    while IFS= read -r _at; do
        hook_word_has_subst "${_E[${_at%:*}]:-}" && return 0
    done < <(_opt_at "$@")
    return 1
}

# _has_subst <from> [bare] - 0 when a word of the launch from index <from>
# on holds a command substitution; with `bare`, only an unquoted one.
_has_subst() {
    local _i _test=hook_word_has_subst
    [[ "${2:-}" == bare ]] && _test=hook_word_has_bare_subst
    for ((_i = $1; _i < ${#_E[@]}; _i++)); do
        "${_test}" "${_E[_i]}" && return 0
    done
    return 1
}

# _block_subst <what> <fix> - fail closed on a command substitution.
_block_subst() {
    hook_block "$1 built by a command substitution cannot be checked (fail closed)." "$2"
}

# _positionals_at <value-opts> <from> - the index of every positional word
# from index <from> on, one per line, skipping the value of every option
# listed in <value-opts>.
_positionals_at() {
    local _i _found=1
    for ((_i = $2; _i < ${#_W[@]}; _i++)); do
        case "${_W[_i]}" in
            --*=*) ;;
            -*) [[ "$1" == *" ${_W[_i]} "* ]] && _i=$((_i + 1)) ;;
            *) printf '%s\n' "${_i}"; _found=0 ;;
        esac
    done
    return "${_found}"
}

# _positional <value-opts> <from> - the first positional word (see above).
_positional() {
    local _i
    _i="$(_positionals_at "$@" | head -n 1)"
    [[ -n "${_i}" ]] || return 1
    printf '%s' "${_W[_i]}"
}

# _gh <args> - run gh from the session's working directory.
_gh() {
    if [[ -n "${_CWD}" && -d "${_CWD}" ]]; then
        (cd -- "${_CWD}" && gh "$@")
    else
        gh "$@"
    fi
}

# _path <file> - <file> resolved against the session's working directory.
_path() {
    if [[ "$1" == /* || -z "${_CWD}" ]]; then
        printf '%s' "$1"
    else
        printf '%s/%s' "${_CWD}" "$1"
    fi
}

_fail_closed() {
    hook_block "$1 (fail closed: a merge is allowed only once the approval check has run)" \
        "Fix the lookup (network, auth, repo, PR selector) and retry; do not work around this hook."
}

# _repo_of <-R value or ''> - print owner/repo: the -R value (a HOST/ prefix
# dropped), else the current directory's repo from gh repo view.
_repo_of() {
    local _r="$1"
    if [[ -z "${_r}" ]]; then
        _r="$(_gh repo view --json nameWithOwner -q .nameWithOwner)" || return 1
    fi
    [[ "${_r}" =~ ([^/[:space:]]+/[^/[:space:]]+)$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# _gate <owner/repo> <number> - block the merge unless lib/approval.sh
# passes it on the PR's labels and comments.
_gate() {
    local _repo="$1" _pr="$2" _json _labels _records _reason _rc
    local _what="merge of ${_repo}#${_pr}"
    # Each gh call is checked by its own exit status (never through a pipe).
    _json="$(_gh api --paginate "repos/${_repo}/issues/${_pr}/labels")" \
        || _fail_closed "${_what}: cannot read the PR labels"
    _labels="$(jq -r '.[].name' <<<"${_json}")" \
        || _fail_closed "${_what}: cannot read the PR labels"
    _json="$(_gh api --paginate "repos/${_repo}/issues/${_pr}/comments")" \
        || _fail_closed "${_what}: cannot read the PR comments"
    _records="$(mktemp)" || _fail_closed "${_what}: cannot create a temp file"
    # One NUL-terminated `<author_association>\t<body>` record per comment,
    # the input format of approval_evaluate.
    if ! jq -j '.[] | .author_association + "\t" + (.body // "") + "\u0000"' \
        <<<"${_json}" >"${_records}"; then
        rm -f -- "${_records}"
        _fail_closed "${_what}: cannot read the PR comments"
    fi
    _reason="$(approval_evaluate "${_labels}" <"${_records}")"
    _rc=$?
    rm -f -- "${_records}"
    [[ "${_rc}" -eq 0 ]] && return 0
    hook_block "${_what}: milestone-gate acceptance PR without the maintainer's approval - ${_reason}" \
        "The maintainer approves by commenting on the PR (OWNER, no [claude]/[codex] marker); agreement in the conversation does not count." \
        "Wait for that comment; never write it on the maintainer's behalf."
}

# _check_pr_merge - resolve the PR of a `gh pr merge` launch, then gate it.
_check_pr_merge() {
    local _sel _repo _pr=''
    local -a _view=(pr view --json number -q .number)
    # A substitution decodes to '_': `gh pr merge "$(printf 7)"` would be
    # judged as the PR '_' while the shell merges PR 7.
    _has_subst 2 && _block_subst "gh pr merge: a selector, -R or flag" \
        "Spell the PR number and -R owner/repo out literally."
    _sel="$(_positional "${_MERGE_VALUE_OPTS}" "$((_ARG0 + 1))")"
    _repo="$(_opt -R --repo)"
    if [[ "${_sel}" =~ ^https?://[^/]+/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
        [[ -n "${_repo}" ]] || _repo="${BASH_REMATCH[1]}"
        _pr="${BASH_REMATCH[2]}"
    elif [[ "${_sel}" =~ ^#?([0-9]+)$ ]]; then
        _pr="${BASH_REMATCH[1]}"
    else
        [[ -n "${_sel}" ]] && _view+=("${_sel}")
        [[ -n "${_repo}" ]] && _view+=(--repo "${_repo}")
        _pr="$(_gh "${_view[@]}")" || _pr=''
        [[ "${_pr}" =~ ^[0-9]+$ ]] \
            || _fail_closed "gh pr merge: cannot resolve the PR number of '${_sel:-the current branch}'"
    fi
    _repo="$(_repo_of "${_repo}")" || _fail_closed "gh pr merge #${_pr}: cannot resolve the repository"
    _gate "${_repo}" "${_pr}"
}

# _api_endpoint - the endpoint of a `gh api` launch, leading / dropped.
_api_endpoint() {
    local _ep
    _ep="$(_positional "${_API_VALUE_OPTS}" 2)" || return 1
    printf '%s' "${_ep#/}"
}

# _api_is_read - 0 when a gh api launch only reads: the last -X / --method
# is GET / DELETE / HEAD, or, with none, no field or --input makes gh POST.
_api_is_read() {
    local _m
    if _m="$(_opt -X --method)"; then
        [[ "${_m^^}" =~ ^(GET|DELETE|HEAD)$ ]]
        return
    fi
    ! _opt_at -f --raw-field -F --field --input >/dev/null
}

# _check_api_subst - fail closed on a gh api launch whose endpoint, or any
# other bare word, comes from a command substitution: it may expand to a
# merge or comments endpoint (it decodes to '_', matching neither check)
# or to options the hook never saw. A read of a built endpoint passes.
_check_api_subst() {
    local _i _n=0
    # Unquoted, it word-splits: `gh api $(printf '%s' '-X PUT') <merge>`.
    _has_subst 2 bare && _block_subst "gh api: an unquoted word" \
        "Spell the options and endpoint out literally, or quote the substitution."
    while IFS= read -r _i; do
        _n=$((_n + 1))
        hook_word_has_subst "${_E[_i]}" || continue
        [[ "${_n}" -eq 1 ]] && _api_is_read && continue
        _block_subst "gh api: an endpoint (or bare word) of a write" \
            "Spell the endpoint out literally (a separate step may compute it first)."
    done < <(_positionals_at "${_API_VALUE_OPTS}" 2)
    return 0
}

# _check_api_merge <endpoint> - gate a gh api call to .../pulls/<n>/merge.
_check_api_merge() {
    local _re='^repos/([^/]+)/([^/]+)/pulls/([0-9]+)/merge/?$' _repo
    [[ "$1" =~ ${_re} ]] || return 0
    local _pr="${BASH_REMATCH[3]}"
    _repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    if [[ "${_repo}" == '{owner}/{repo}' ]]; then
        _repo="$(_repo_of '')" || _fail_closed "gh api merge #${_pr}: cannot resolve the repository"
    fi
    _gate "${_repo}" "${_pr}"
}

# _judge_body <body> <source> - block a body that reads as a human approval.
_judge_body() {
    approval_is_human_approval OWNER "$1" || return 0
    hook_block "$2 carries the maintainer's approval phrase without a [claude] or [codex] marker." \
        "Only the maintainer writes an approval; an agent never does, not even on request." \
        "An agent comment starts with [claude] or [codex] (a marked body may quote the phrase)."
}

# _read_body <file> <source> - print a body file, blocking when unreadable.
_read_body() {
    local _f
    _f="$(_path "$1")"
    if [[ "$1" == - || ! -r "${_f}" ]]; then
        hook_block "$2: cannot read the body from '$1' to check it for a forged approval (fail closed)." \
            "Write the body to a file first (a separate step), then pass --body-file <file>."
    fi
    cat -- "${_f}"
}

# _check_gh_body - anti-forgery for gh pr|issue comment / review / create.
_check_gh_body() {
    local _src _body _file
    _src="gh $(_sub) body"
    _has_subst "$((_ARG0 + 1))" bare && _block_subst "gh $(_sub): an unquoted word" \
        "Spell the options out literally, or quote the substitution."
    if _opt_has_subst --body -b --body-file -F; then
        hook_block "${_src}: a body (or body file name) with a command substitution cannot be checked (fail closed)." \
            "Write the body to a file first, then pass --body-file <literal path>."
    fi
    # Every value, not only the one gh keeps: a repeated flag hides none.
    while IFS= read -r -d '' _body; do
        _judge_body "${_body}" "${_src}"
    done < <(_opt_values --body -b)
    while IFS= read -r -d '' _file; do
        _body="$(_read_body "${_file}" "${_src}")" || exit 2
        _judge_body "${_body}" "${_src} file '${_file}'"
    done < <(_opt_values --body-file -F)
    return 0
}

# _api_field_body <value of -f/-F/--field/--raw-field> <is -F/--field> -
# print the comment body a field sets; 1 when it sets none, 2 when its
# @file cannot be read (already reported).
_api_field_body() {
    [[ "$1" == body=* ]] || return 1
    local _v="${1#body=}"
    if [[ "$2" == 1 && "${_v}" == @* ]]; then
        _read_body "${_v#@}" "gh api comment body" || exit 2
    else
        printf '%s' "${_v}"
    fi
}

# _check_api_fields <is -F/--field> <name>... - judge the comment body that
# any of those field options sets (every form: -f x, -fx, -f=x, --field=x).
_check_api_fields() {
    local _typed="$1" _v _body _rc
    shift
    while IFS= read -r -d '' _v; do
        _body="$(_api_field_body "${_v}" "${_typed}")"
        _rc=$?
        [[ "${_rc}" -eq 2 ]] && exit 2
        [[ "${_rc}" -eq 0 ]] && _judge_body "${_body}" "gh api comment body"
    done < <(_opt_values "$@")
    return 0
}

# _check_api_comment <endpoint> - anti-forgery for gh api writes to
# .../comments (a read, -X GET / DELETE, passes).
_check_api_comment() {
    [[ "$1" =~ /comments(/[0-9]+)?/?(\?.*)?$ ]] || return 0
    local _body _input
    _api_is_read && return 0
    # --input too: its substitution decodes to '_', and a benign '_' file
    # must not stand in for the file the shell really submits.
    if _opt_has_subst -f --raw-field -F --field --input; then
        hook_block "gh api comment field or --input with a command substitution cannot be checked (fail closed)." \
            "Write the body to a file first, then pass --input <literal path>."
    fi
    _check_api_fields 0 -f --raw-field
    _check_api_fields 1 -F --field
    if _input="$(_opt --input)"; then
        _body="$(_read_body "${_input}" "gh api --input")" || exit 2
        _judge_body "$(jq -r '.body // empty' <<<"${_body}" 2>/dev/null)" "gh api --input '${_input}'"
    fi
    return 0
}

# _check_sub_words - fail closed when a word naming the gh sub-command
# (`gh <group> [-R x] <sub>`, or `gh api`) holds a command substitution:
# `gh pr "$(echo merge)" 7` merges while the hook reads `gh pr _`.
_check_sub_words() {
    local _i _last="${_ARG0}"
    [[ "${_W[1]:-}" == api ]] && _last=1
    for ((_i = 1; _i <= _last; _i++)); do
        hook_word_has_subst "${_E[_i]:-}" || continue
        _block_subst "gh: a sub-command word" "Spell the gh sub-command out literally."
    done
}

# _check_launch <encoded sub-command> - judge one launch; blocks (exit 2)
# or returns.
_check_launch() {
    _load_launch "$1" || return 0
    local _ep
    _check_sub_words
    case "$(_sub)" in
        "pr merge") _check_pr_merge ;;
        "pr comment"|"pr review"|"pr create"|"issue comment"|"issue create") _check_gh_body ;;
        api)
            _check_api_subst
            _ep="$(_api_endpoint)" || return 0
            _check_api_merge "${_ep}"
            _check_api_comment "${_ep}" ;;
    esac
    return 0
}

main() {
    hook_read_input
    local _cmd _sub
    _cmd="$(hook_command)"
    _CWD="$(hook_field '.cwd')"
    [[ -n "${_cmd}" ]] || hook_allow
    while IFS= read -r _sub; do
        _check_launch "${_sub}"
    done < <(hook_subcommands_raw "${_cmd}")
    hook_allow
}

main "$@"
