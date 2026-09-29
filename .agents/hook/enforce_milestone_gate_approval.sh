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
#      human approval by approval_is_human_approval: a body holding the
#      approval phrase must start with [claude] or [codex]. A body the hook
#      cannot read (stdin, a missing file, a command substitution) blocks.
# The approval rule and phrase live only in lib/approval.sh; this hook
# fetches data and never restates the rule. Only real gh launches count
# (lib/subcommand.sh): quoted text, commit messages and heredoc bodies that
# merely mention gh are data. Everything else passes silently, without
# calling gh.

# shellcheck source-path=SCRIPTDIR/lib
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
# leading timeout(1) and its options are skipped); fail when it is no gh.
_load_launch() {
    local -a _enc
    local _i=0
    read -r -a _enc <<<"$1"
    if [[ "${_enc[0]:-}" =~ ^g?timeout$ ]]; then
        _i=1
        while [[ "${_enc[_i]:-}" == -* ]]; do _i=$((_i + 1)); done
        _i=$((_i + 1))
    fi
    [[ "${_enc[_i]:-}" == gh || "${_enc[_i]:-}" == */gh ]] || return 1
    _E=("${_enc[@]:_i}")
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

# _opt_at <name>... - print the index of the value of the first given
# option, as `<index>` (separate word) or `<index>=` (inside --name=value).
_opt_at() {
    local _i _n
    for ((_i = 2; _i < ${#_W[@]}; _i++)); do
        for _n in "$@"; do
            if [[ "${_W[_i]}" == "${_n}" ]]; then
                printf '%s' "$((_i + 1))"; return 0
            elif [[ "${_n}" == --* && "${_W[_i]}" == "${_n}="* ]]; then
                printf '%s=' "${_i}"; return 0
            fi
        done
    done
    return 1
}

# _opt <name>... - the decoded value of the first given option.
_opt() {
    local _at
    _at="$(_opt_at "$@")" || return 1
    if [[ "${_at}" == *= ]]; then
        printf '%s' "${_W[${_at%=}]#*=}"
    else
        printf '%s' "${_W[_at]:-}"
    fi
}

# _opt_has_subst <name>... - 0 when that option's value holds a command
# substitution (the hook cannot know what it expands to).
_opt_has_subst() {
    local _at
    _at="$(_opt_at "$@")" || return 1
    hook_word_has_subst "${_E[${_at%=}]:-}"
}

# _positional <value-opts> <from> - the first positional word from index
# <from> on, skipping the value of every option listed in <value-opts>.
_positional() {
    local _i
    for ((_i = $2; _i < ${#_W[@]}; _i++)); do
        case "${_W[_i]}" in
            --*=*) ;;
            -*) [[ "$1" == *" ${_W[_i]} "* ]] && _i=$((_i + 1)) ;;
            *) printf '%s' "${_W[_i]}"; return 0 ;;
        esac
    done
    return 1
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
    local _repo="$1" _pr="$2" _labels _records _reason _rc
    local _what="merge of ${_repo}#${_pr}"
    _labels="$(_gh api --paginate "repos/${_repo}/issues/${_pr}/labels" \
        | jq -r '.[].name')" || _fail_closed "${_what}: cannot read the PR labels"
    _records="$(mktemp)" || _fail_closed "${_what}: cannot create a temp file"
    # One NUL-terminated `<author_association>\t<body>` record per comment,
    # the input format of approval_evaluate.
    if ! _gh api --paginate "repos/${_repo}/issues/${_pr}/comments" \
        | jq -j '.[] | .author_association + "\t" + (.body // "") + "\u0000"' >"${_records}"; then
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
    if _opt_has_subst --body -b; then
        hook_block "${_src}: an inline body with a command substitution cannot be checked (fail closed)." \
            "Write the body to a file first, then pass --body-file <file>."
    fi
    _body="$(_opt --body -b)" && _judge_body "${_body}" "${_src}"
    if _file="$(_opt --body-file -F)"; then
        _body="$(_read_body "${_file}" "${_src}")" || exit 2
        _judge_body "${_body}" "${_src} file '${_file}'"
    fi
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

# _check_api_comment <endpoint> - anti-forgery for gh api writes to
# .../comments (a read, -X GET / DELETE, passes).
_check_api_comment() {
    [[ "$1" =~ /comments(/[0-9]+)?/?(\?.*)?$ ]] || return 0
    local _m _i _typed _body _input _rc
    _m="$(_opt -X --method)"
    [[ "${_m^^}" =~ ^(GET|DELETE|HEAD)$ ]] && return 0
    for ((_i = 2; _i < ${#_W[@]}; _i++)); do
        case "${_W[_i]}" in
            -f|--raw-field) _typed=0 ;;
            -F|--field) _typed=1 ;;
            *) continue ;;
        esac
        _i=$((_i + 1))
        hook_word_has_subst "${_E[_i]:-}" \
            && hook_block "gh api comment field with a command substitution cannot be checked (fail closed)."
        _body="$(_api_field_body "${_W[_i]:-}" "${_typed}")"
        _rc=$?
        [[ "${_rc}" -eq 2 ]] && exit 2
        [[ "${_rc}" -eq 0 ]] && _judge_body "${_body}" "gh api comment body"
    done
    if _input="$(_opt --input)"; then
        _body="$(_read_body "${_input}" "gh api --input")" || exit 2
        _judge_body "$(jq -r '.body // empty' <<<"${_body}" 2>/dev/null)" "gh api --input '${_input}'"
    fi
    return 0
}

# _check_launch <encoded sub-command> - judge one launch; blocks (exit 2)
# or returns.
_check_launch() {
    _load_launch "$1" || return 0
    local _ep
    case "$(_sub)" in
        "pr merge") _check_pr_merge ;;
        "pr comment"|"pr review"|"pr create"|"issue comment"|"issue create") _check_gh_body ;;
        api)
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
