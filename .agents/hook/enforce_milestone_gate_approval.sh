#!/usr/bin/env bash
# .agents/hook/enforce_milestone_gate_approval.sh - Claude Code PreToolUse
# hook (matcher: Bash), registered in .claude/settings.json (issue #190).
#
# The agent-side half of the milestone-gate approval (#187). GitHub cannot
# tell the maintainer from an agent posting with the maintainer's token, so
# this hook BLOCKS (exit 2, reason on stderr) what only an agent could do:
#   1. merge gate: `gh pr merge [<sel>]` (any flags, --auto included) and
#      `gh api .../repos/<owner>/<repo>/pulls/<n>/merge` (a full URL or a
#      query string included). The repo comes from -R / --repo, a PR URL
#      or the api path, else `gh repo view`; a branch or missing selector
#      is resolved with `gh pr view`. The PR's labels and comments are
#      fetched with gh and handed to approval_evaluate of lib/approval.sh
#      (the same predicate the milestone-gate workflow runs). A failed
#      evaluation blocks, naming what is missing; ANY failed lookup blocks
#      too (fail closed). A GraphQL mutation that merges (mergePullRequest,
#      enablePullRequestAutoMerge, mergeBranch) blocks outright.
#   2. anti-forgery: the body of `gh pr comment|review|create|new`,
#      `gh issue comment|create|new` (--body / -b, --body-file / -F read
#      from disk), the --comment / -c of `gh pr|issue close|reopen` and
#      the body of `gh api` writes to .../comments (-f / -F / --raw-field /
#      --field body=..., body=@file, --input <json>) must not read as a
#      human approval by approval_is_human_approval. Every occurrence of a
#      repeated flag is judged, in every form (-b x, -bx, -b=x, --body=x),
#      and the last -X / --method decides a read. A body holding the
#      approval phrase must start with [claude] or [codex]. A body the hook
#      cannot read (stdin, a missing file) blocks. A GraphQL mutation that
#      writes a comment (addComment, updateIssueComment) blocks outright.
#   3. the CLOSED rule (fail closed where static parsing cannot follow the
#      shell): the hook judges only what it can read literally.
#      - A relevant gh command (`gh api`, any call; the pr / issue
#        sub-commands above) with ANY word holding an expansion the shell
#        resolves ($VAR, ${...}, $'...', $(...), `...`, <(...), a glob or
#        a brace expansion; see hook_word_has_expansion of
#        lib/subcommand.sh) blocks: re-run it with literal arguments.
#      - A gh launch whose sub-command cannot be told (an expansion before
#        or in it, `gh $SUB`, `--` before it) blocks, and so does an
#        unknown top-level word (a gh alias or extension may run anything).
#      - gh root flags before the sub-command: -R / --repo / --repo= and
#        -h / --help are read as if they followed it; any other flag
#        there blocks when the sub-command is relevant.
#      - Combined short options (-eb x) block in a relevant command; only
#        a value attached to a flag the hook reads (-Rx, -bx, -Fx, -fx,
#        -Xx ...) is taken.
#      - A launch whose command name is an expansion (`$GH pr merge`,
#        `eval "$CMD"`, `bash -c "$CMD"`) blocks, unless its last path
#        segment is a literal name other than gh ($HOME/bin/tool).
#      - gh run by another command (nice gh, xargs gh) blocks when the
#        sub-command is relevant: run gh directly.
#      - A heredoc or here-string a shell reads as its script (sh <<EOF,
#        bash <<< '...') is judged like any command line (lib/subcommand.sh);
#        a script FILE run by name (bash x.sh, python x.py, just ...) is
#        not read (a documented limit: the server-side status check of
#        #187 still refuses an unapproved merge).
#   4. --help / -h (as a flag of its own, not an option's value) only
#      prints usage: such a launch passes without calling gh.
#   5. raw-text tripwire (codex round 5), the backstop of the closed rule:
#      a relevant gh call pattern (gh [root flags] pr merge|comment|review|
#      create|new|close|reopen, issue comment|create|new|close|reopen, gh
#      api) or the approval phrase found in the RAW command text (heredoc
#      bodies and here-strings included) more often than in the launches
#      the structured pass checked blocks: some occurrence escaped it. The
#      accepted cost: text that merely mentions such a call or the phrase
#      (a commit message) is blocked too; pass it with -F / --file.
# The approval rule and phrase live only in lib/approval.sh; this hook
# fetches data and never restates the rule. Only real launches count
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
# index of its sub-command word (_ARG0: `merge` of `gh pr merge`, `api` of
# `gh api`) and the session's working directory from the payload (_CWD).
# Once a relevant launch is normalised, _W / _E read `gh <group> [<sub>]
# <every other word, in order>`, root flags included.
_W=()
_E=()
_ARG0=0
_CWD=''
# Set by _load_launch / _parse_path / _classify for the launch.
_WRAP=''
_UNK=''
_ROOT_BAD=''
_GROUP=''
_SUBC=''
_PATH_IDX=()
_REST=()
_REL=0
_VALUE_OPTS=''
_ATTACH=''
# What the structured pass checked and let through (the tripwire compares).
_CHECKED=0
_CHECKED_TEXT=''

# Flags taking a value, per command, so positionals and option values can
# be told apart; _ATTACH (per command, in _classify) lists the short flags
# whose attached value the hook reads (-Rx, -bx ...).
readonly _MERGE_VALUE_OPTS=' -R --repo -b --body -F --body-file -t --subject -A --author-email --match-head-commit '
readonly _API_VALUE_OPTS=' -X --method -f -F --field --raw-field -H --header --input -q --jq -t --template --hostname --cache -p --preview '
readonly _BODY_VALUE_OPTS=' -R --repo -b --body -F --body-file '
readonly _CREATE_VALUE_OPTS=' -R --repo -b --body -F --body-file -t --title -B --base -H --head -a --assignee -l --label -m --milestone -p --project -r --reviewer -T --template --recover '
readonly _CLOSE_VALUE_OPTS=' -R --repo -c --comment -r --reason '
# gh's built-in top-level commands; any other first word is an alias or an
# extension, which may run anything.
readonly _GH_COMMANDS=' accessibility agent-task alias api attestation auth browse cache co codespace completion config copilot extension gist gpg-key help issue label org pr preview project release repo ruleset run search secret ssh-key status variable version workflow '

# _is_gh <encoded word> - 0 when the word names gh (gh, /path/to/gh).
_is_gh() {
    local _w
    _w="$(hook_word "$1")"
    [[ "${_w}" == gh || "${_w}" == */gh ]]
}

# _block_exp <what> - fail closed on a shell expansion (closed rule).
_block_exp() {
    hook_block "$1 holds a shell expansion (a variable, command substitution, glob or brace) the hook cannot resolve (fail closed)." \
        "Re-run gh with literal arguments: compute any value in a separate step first, then spell it out." \
        "A body goes in a file first, passed as --body-file <literal path>."
}

# _block_root <flag> - fail closed on a gh root flag the hook cannot read.
_block_root() {
    hook_block "gh: the root flag '$1' before the sub-command cannot be checked (fail closed)." \
        "Put the flags after the sub-command (gh pr merge 7 -R owner/repo); only -R / --repo may precede it."
}

# _load_launch <encoded sub-command> - fill _W / _E from a gh launch (a
# leading timeout(1), its options and duration are skipped, by
# hook_timeout_lead of lib/subcommand.sh); fail when it launches no gh. A
# gh word behind another command (nice gh, xargs gh) sets _WRAP to that
# command. A command name built by an expansion blocks (closed rule),
# unless its last path segment is a literal name other than gh.
_load_launch() {
    local _lead _i _g=-1 _base
    local -a _words
    _lead="$(hook_timeout_lead "$1")"
    read -r -a _words <<<"${1#"${_lead}"}"
    [[ "${#_words[@]}" -gt 0 ]] || return 1
    _WRAP=''
    if _is_gh "${_words[0]}"; then
        _g=0
    else
        _base="${_words[0]##*/}"
        if hook_word_has_expansion "${_base}"; then
            hook_block "the command name '$(hook_word "${_words[0]}")' is a shell expansion: it may run gh unseen (fail closed)." \
                "Spell the command out literally (a separate step may look it up first); run gh directly, not through eval or bash -c \"\$VAR\"."
        fi
        for ((_i = 1; _i < ${#_words[@]}; _i++)); do
            _is_gh "${_words[_i]}" || continue
            _g="${_i}"
            _WRAP="$(hook_word "${_words[0]}")"
            break
        done
        [[ "${_g}" -ge 0 ]] || return 1
    fi
    _E=("${_words[@]:_g}")
    _W=()
    for _i in "${!_E[@]}"; do _W[_i]="$(hook_word "${_E[_i]}")"; done
    return 0
}

# _parse_path - find the gh command path the way gh (cobra) does: flags
# before it are skipped, `--flag` / `-f` without `=` taking the next word.
# `pr` and `issue` take a second path word. Sets _GROUP / _SUBC, the path
# indexes (_PATH_IDX), every other index in order (_REST), the first
# unknown root flag (_ROOT_BAD) and, when an expansion or `--` comes
# before the path is complete, _UNK (the path cannot be told).
_parse_path() {
    local _i _need=1 _w
    _PATH_IDX=()
    _REST=()
    _ROOT_BAD=''
    _UNK=''
    for ((_i = 1; _i < ${#_E[@]}; _i++)); do
        if [[ "${#_PATH_IDX[@]}" -ge "${_need}" ]]; then
            _REST+=("${_i}")
            continue
        fi
        _w="${_W[_i]}"
        if hook_word_has_expansion "${_E[_i]}"; then
            _UNK="${_w}"
            return 0
        fi
        case "${_w}" in
            --) _UNK='--'; return 0 ;;
            -R|--repo)
                _REST+=("${_i}")
                _i=$((_i + 1))
                [[ "${_i}" -lt "${#_E[@]}" ]] || continue
                if hook_word_has_expansion "${_E[_i]}"; then
                    _UNK="${_W[_i]}"
                    return 0
                fi
                _REST+=("${_i}") ;;
            -R?*|--repo=*|-h|--help) _REST+=("${_i}") ;;
            --*=*)
                [[ -n "${_ROOT_BAD}" ]] || _ROOT_BAD="${_w}" ;;
            --*|-?)
                # --flag or -f: gh takes the next word as its value.
                [[ -n "${_ROOT_BAD}" ]] || _ROOT_BAD="${_w}"
                _i=$((_i + 1))
                if [[ "${_i}" -lt "${#_E[@]}" ]] && hook_word_has_expansion "${_E[_i]}"; then
                    _UNK="${_W[_i]}"
                    return 0
                fi ;;
            -*)
                # -abc (a cluster) or a lone -: no value word.
                [[ -n "${_ROOT_BAD}" ]] || _ROOT_BAD="${_w}" ;;
            *)
                _PATH_IDX+=("${_i}")
                [[ "${#_PATH_IDX[@]}" -eq 1 && ("${_w}" == pr || "${_w}" == issue) ]] && _need=2 ;;
        esac
    done
    _GROUP=''
    _SUBC=''
    [[ "${#_PATH_IDX[@]}" -ge 1 ]] && _GROUP="${_W[_PATH_IDX[0]]}"
    [[ "${#_PATH_IDX[@]}" -ge 2 ]] && _SUBC="${_W[_PATH_IDX[1]]}"
    return 0
}

# _classify - set _REL (1 when the launch is one the hook judges) with the
# value options (_VALUE_OPTS) and attachable short flags (_ATTACH) of it.
_classify() {
    _REL=1
    case "${_GROUP} ${_SUBC}" in
        "api "*) _VALUE_OPTS="${_API_VALUE_OPTS}"; _ATTACH=XfFHqtp ;;
        "pr merge") _VALUE_OPTS="${_MERGE_VALUE_OPTS}"; _ATTACH=RbFtA ;;
        "pr comment"|"pr review"|"issue comment") _VALUE_OPTS="${_BODY_VALUE_OPTS}"; _ATTACH=RbF ;;
        "pr create"|"pr new"|"issue create"|"issue new") _VALUE_OPTS="${_CREATE_VALUE_OPTS}"; _ATTACH=RbFt ;;
        "pr close"|"pr reopen"|"issue close"|"issue reopen") _VALUE_OPTS="${_CLOSE_VALUE_OPTS}"; _ATTACH=Rc ;;
        *) _REL=0 ;;
    esac
}

# _normalize - rewrite _W / _E as `gh <path words> <other words>`, so a
# root flag reads as if it followed the sub-command, and set _ARG0.
_normalize() {
    local -a _e=("${_E[0]}") _w=(gh)
    local _i
    for _i in "${_PATH_IDX[@]}" "${_REST[@]}"; do
        _e+=("${_E[_i]}")
        _w+=("${_W[_i]}")
    done
    _E=("${_e[@]}")
    _W=("${_w[@]}")
    _ARG0="${#_PATH_IDX[@]}"
}

# _check_closed - the closed rule on a relevant launch: no word may hold a
# shell expansion, and no short options may be combined (-eb x), since
# the hook reads only what it can see literally.
_check_closed() {
    local _i _w
    for ((_i = 1; _i < ${#_E[@]}; _i++)); do
        hook_word_has_expansion "${_E[_i]}" && _block_exp "gh $(_sub): the word '${_W[_i]}'"
    done
    for ((_i = _ARG0 + 1; _i < ${#_W[@]}; _i++)); do
        _w="${_W[_i]}"
        if [[ "${_VALUE_OPTS}" == *" ${_w} "* ]]; then
            _i=$((_i + 1))
            continue
        fi
        [[ "${_w}" == -[!-]?* && "${_ATTACH}" != *"${_w:1:1}"* ]] || continue
        hook_block "gh $(_sub): combined short options '${_w}' cannot be checked (fail closed)." \
            "Spell each short option separately (-e -b <body>); only a value flag the hook reads (one of ${_ATTACH}) may carry an attached value."
    done
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

# _api_endpoint - the endpoint of a `gh api` launch, as written.
_api_endpoint() {
    _positional "${_API_VALUE_OPTS}" 2
}

# _api_path <endpoint> - the endpoint as a lower-case API path: a full URL's
# scheme and host, leading slashes, a GHES api/v3/ prefix, the query string
# and a fragment dropped (GitHub serves all of them the same route).
_api_path() {
    local _p="${1,,}"
    [[ "${_p}" =~ ^[a-z][a-z0-9+.-]*://[^/]*(/.*)?$ ]] && _p="${BASH_REMATCH[1]}"
    while [[ "${_p}" == /* ]]; do _p="${_p#/}"; done
    _p="${_p#api/v3/}"
    _p="${_p%%\?*}"
    printf '%s' "${_p%%#*}"
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

# _check_api_graphql <endpoint> - block a GraphQL mutation that merges a
# PR or writes a comment: the hook cannot judge its body, and gh pr merge /
# gh pr comment do the same job where it can. The query and fields are
# read as gh sends them (-F @file and --input from disk, --input decoded
# as JSON so a \u escape hides no name).
_check_api_graphql() {
    [[ "$(_api_path "$1")" == graphql ]] || return 0
    local _text='' _v _in
    while IFS= read -r -d '' _v; do
        _text+="${_v}"$'\n'
    done < <(_opt_values -f --raw-field)
    while IFS= read -r -d '' _v; do
        if [[ "${_v}" == *=@* ]]; then
            _v="$(_read_body "${_v#*=@}" "gh api graphql field")" || exit 2
        fi
        _text+="${_v}"$'\n'
    done < <(_opt_values -F --field)
    if _in="$(_opt --input)"; then
        _v="$(_read_body "${_in}" "gh api graphql --input")" || exit 2
        _text+="${_v}"$'\n'"$(jq -r '[.. | strings] | join("\n")' <<<"${_v}" 2>/dev/null)"
    fi
    if [[ "${_text}" =~ (mergePullRequest|enablePullRequestAutoMerge|mergeBranch) ]]; then
        hook_block "gh api graphql: the ${BASH_REMATCH[1]} mutation bypasses the milestone-gate check (fail closed)." \
            "Merge with gh pr merge, which this hook gates."
    fi
    if [[ "${_text}" =~ (addComment|updateIssueComment) ]]; then
        hook_block "gh api graphql: the ${BASH_REMATCH[1]} mutation writes a comment the hook cannot judge (fail closed)." \
            "Comment with gh pr comment / gh issue comment --body-file <file>, which this hook checks."
    fi
    return 0
}

# _check_api_unclean <path> - fail closed on a write whose path the hook
# cannot compare literally (percent-encoding, // or dot segments).
_check_api_unclean() {
    case "/$1/" in
        *%*|*//*|*/./*|*/../*) ;;
        *) return 0 ;;
    esac
    _api_is_read && return 0
    hook_block "gh api: the endpoint '$1' of a write is not a plain path the hook can check (fail closed)." \
        "Spell the endpoint as a plain path (repos/<owner>/<repo>/...)."
}

# _check_api - judge a gh api launch: GraphQL, merge and comment writes.
_check_api() {
    local _ep
    _ep="$(_api_endpoint)" || return 0
    _check_api_graphql "${_ep}"
    _ep="$(_api_path "${_ep}")"
    _check_api_unclean "${_ep}"
    _check_api_merge "${_ep}"
    _check_api_comment "${_ep}"
}

# _check_api_merge <path> - gate a gh api call to .../pulls/<n>/merge.
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

# _check_gh_body - anti-forgery for gh pr|issue comment / review / create /
# new.
_check_gh_body() {
    local _src _body _file
    _src="gh $(_sub) body"
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

# _check_close_comment - anti-forgery for the --comment / -c of gh pr|issue
# close / reopen (every occurrence).
_check_close_comment() {
    local _body
    while IFS= read -r -d '' _body; do
        _judge_body "${_body}" "gh $(_sub) --comment"
    done < <(_opt_values --comment -c)
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

# _check_api_comment <path> - anti-forgery for gh api writes to
# .../comments (a read, -X GET / DELETE, passes).
_check_api_comment() {
    [[ "$1" =~ /comments(/[0-9]+)?/?$ ]] || return 0
    local _body _input
    _api_is_read && return 0
    _check_api_fields 0 -f --raw-field
    _check_api_fields 1 -F --field
    if _input="$(_opt --input)"; then
        _body="$(_read_body "${_input}" "gh api --input")" || exit 2
        _judge_body "$(jq -r '.body // empty' <<<"${_body}" 2>/dev/null)" "gh api --input '${_input}'"
    fi
    return 0
}

# _asks_help - 0 when the (normalised, literal) launch carries -h / --help
# as a flag of its own, not as the value of a valued option and not after
# `--`: gh then prints usage and runs nothing.
_asks_help() {
    local _i _w
    for ((_i = 1; _i < ${#_W[@]}; _i++)); do
        _w="${_W[_i]}"
        case "${_w}" in
            --) return 1 ;;
            -h|--help) return 0 ;;
        esac
        [[ "${_VALUE_OPTS}" == *" ${_w} "* ]] && _i=$((_i + 1))
    done
    return 1
}

# _check_launch <encoded sub-command> - judge one launch; blocks (exit 2)
# or returns.
_check_launch() {
    _load_launch "$1" || return 0
    _parse_path
    if [[ -n "${_UNK}" ]]; then
        # A wrapped gh (xargs gh ...) is judged only when literally relevant.
        [[ -n "${_WRAP}" ]] && return 0
        [[ "${_UNK}" == -- ]] && hook_block "gh: '--' before the sub-command hides which command runs (fail closed)." \
            "Spell the gh sub-command out first (gh pr merge ...)."
        _block_exp "gh: the word '${_UNK}' before or in the sub-command"
    fi
    _classify
    if [[ "${_REL}" -eq 0 ]]; then
        [[ -z "${_GROUP}" || -n "${_WRAP}" || "${_GH_COMMANDS}" == *" ${_GROUP} "* ]] && return 0
        [[ -n "${_ROOT_BAD}" ]] && _block_root "${_ROOT_BAD}"
        hook_block "gh ${_GROUP}: not a built-in gh command; a gh alias or extension may merge or comment unseen (fail closed)." \
            "Run the built-in gh command it stands for directly."
    fi
    if [[ -n "${_WRAP}" ]]; then
        hook_block "gh ${_GROUP} ${_SUBC} run through '${_WRAP}' cannot be checked (fail closed)." \
            "Run gh directly, with literal arguments."
    fi
    [[ -n "${_ROOT_BAD}" ]] && _block_root "${_ROOT_BAD}"
    _normalize
    _check_closed
    # --help only prints usage: it never merges or writes.
    if ! _asks_help; then
        case "$(_sub)" in
            "pr merge") _check_pr_merge ;;
            "pr close"|"pr reopen"|"issue close"|"issue reopen") _check_close_comment ;;
            api) _check_api ;;
            *) _check_gh_body ;;
        esac
    fi
    _mark_checked
    return 0
}

# _mark_checked - record a relevant launch the structured pass let through.
_mark_checked() {
    local IFS=' '
    _CHECKED=$((_CHECKED + 1))
    _CHECKED_TEXT+="${_W[*]}"$'\n'
}

# _count <needle> <text> - how many times <needle> occurs in <text>.
_count() {
    local _t="$2" _n=0
    while [[ "${_t}" == *"$1"* ]]; do
        _t="${_t#*"$1"}"
        _n=$((_n + 1))
    done
    printf '%s' "${_n}"
}

# _tripwire <command> - the backstop of the closed rule, on the RAW command
# text (heredoc bodies and here-strings included, before any parsing): a
# relevant gh call (gh [root flags] pr merge|comment|review|create|new|
# close|reopen, gh issue comment|create|new|close|reopen, gh api) or the
# approval phrase that occurs more often than in the launches the
# structured pass checked means some of them escaped it (a parser gap, an
# unknown interpreter, plain text): block. Plain text that merely mentions
# such a call (a commit message, an echo) is blocked too.
_tripwire() {
    local _t="${1//\\$'\n'/ }" _q="[\"']?" _raw _phrase
    local _f='([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'
    local _re="(^|[^[:alnum:]_.-])gh${_q}${_f}[[:space:]]+${_q}(pr${_q}${_f}[[:space:]]+${_q}(merge|comment|review|create|new|close|reopen)|issue${_q}${_f}[[:space:]]+${_q}(comment|create|new|close|reopen)|api)([\"';&|)[:space:]]|$)"
    _raw="$(grep -oE -- "${_re}" <<<"${_t}" | wc -l)"
    _phrase="$(approval_phrase)"
    if [[ "${_raw}" -le "${_CHECKED}" ]] \
        && [[ "$(_count "${_phrase}" "${_t}")" -le "$(_count "${_phrase}" "${_CHECKED_TEXT}")" ]]; then
        return 0
    fi
    hook_block "cannot verify this gh call statically: the command text holds a merge / comment gh call or the approval phrase that the hook could not check as a literal gh launch (fail closed)." \
        "Run the gh command on its own with literal arguments; put long text in a file and use --body-file <file>." \
        "Plain text that merely mentions such a gh call or the phrase (a commit message, an echo) is blocked too: use -F / --file (git commit -F <file>)."
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
    _tripwire "${_cmd}"
    hook_allow
}

main "$@"
