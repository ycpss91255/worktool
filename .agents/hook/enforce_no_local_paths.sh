#!/usr/bin/env bash
# .agents/hook/enforce_no_local_paths.sh - Claude Code PreToolUse hook
# (matcher: Bash), registered in .claude/settings.json (issue #233).
#
# The repo is public: a comment, PR or issue body an agent posts must not
# carry a machine-local absolute path (a home directory, a Claude
# scratchpad, /root/). This hook BLOCKS (exit 2, reason on stderr) a gh
# launch whose body holds one; the body is read wherever gh reads it:
#   - inline: --body / -b (every form: -b x, -bx, --body=x) and the
#     --comment / -c of gh pr|issue close / reopen
#   - a file: --body-file / -F of gh pr|issue, gh api -F body=@<file> and
#     gh api --input <file> (relative paths resolve against the payload's
#     cwd, or a `cd` earlier in the same command)
#   - gh api field values (-f / --raw-field / -F / --field)
#   - a heredoc anywhere in a command that launches such a gh call
# The judged gh launches: gh pr|issue create / new / comment / edit /
# review / close / reopen, and every gh api call. The path patterns live
# only in LOCAL_PATH_ERE below; LOCAL_PATH_ALLOWED lists the generic
# example (/home/me/) that doc and test fixtures use on purpose.
#
# The closed rule of #190: a body the hook cannot read literally blocks -
# an inline body or a file path holding a shell expansion ($VAR, $(...),
# a backtick, a glob, a leading ~), a missing or unreadable file, and a
# stdin body (-) with no heredoc in the command.
#
# Only real launches count (lib/subcommand.sh): a path in a commit message,
# an echo, a cd or a redirection is not a gh body. Everything else passes
# silently.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-no-local-paths"

# A local path starts at a word boundary (so src/root/ or a URL path does
# not count) and is a home directory (Linux or macOS), a Claude
# scratchpad or /root/.
readonly LOCAL_PATH_ERE='(^|[^[:alnum:]_.~-])(/home/[^/[:space:]]+/|/Users/[^/[:space:]]+/|/tmp/claude-[0-9]+/|/root/)'
readonly LOCAL_PATH_ALLOWED=' /home/me/ '

# The launch under judgement: encoded words (_E) and the directory its
# relative files resolve against (_CWD). _STDIN is set when a body is read
# from stdin; _REL when any relevant gh launch was seen.
_E=()
_CWD=''
_STDIN=0
_REL=0

# _local_paths <text> - print each distinct local path prefix in <text>,
# the allowed examples left out.
_local_paths() {
    local _p
    while IFS= read -r _p; do
        _p="/${_p#*/}"
        [[ "${LOCAL_PATH_ALLOWED}" == *" ${_p} "* ]] || printf '%s\n' "${_p}"
    done < <(grep -oE -- "${LOCAL_PATH_ERE}" <<<"$1" | sort -u)
}

# _judge <text> <source> - block when <text> holds a local path.
_judge() {
    local _found
    _found="$(_local_paths "$1")"
    [[ -z "${_found}" ]] && return 0
    hook_block "$2 holds a machine-local absolute path: ${_found//$'\n'/, }" \
        "The repo is public: rewrite it as a repo-relative path (lib/log.sh:12) or a placeholder such as <scratch>/ or <worktree>/ before posting." \
        "The generic example /home/me/ is allowed."
}

# _block_literal <what> - the closed rule.
_block_literal() {
    hook_block "$1 cannot be read literally (a shell expansion or stdin; fail closed)." \
        "Re-run gh with literal arguments: write the body to a file first, then pass --body-file <literal path>."
}

# _expands <encoded word> - 0 when the shell would expand the word.
_expands() {
    local _w
    hook_word_has_subst "$1" && return 0
    _w="$(hook_word "$1")"
    [[ "${_w}" == *'$'* || "${_w}" == *'`'* ]]
}

# _resolve <path> - <path> against the launch's directory.
_resolve() {
    if [[ "$1" == /* || -z "${_CWD}" ]]; then
        printf '%s' "$1"
    else
        printf '%s/%s' "${_CWD}" "$1"
    fi
}

# _judge_file <path> <source> - judge a body file's content; `-` is stdin.
_judge_file() {
    local _f="$1" _text
    if [[ "${_f}" == - ]]; then
        _STDIN=1
        return 0
    fi
    if [[ "${_f}" == *['$`*?[']* || "${_f}" == '~'* ]]; then
        _block_literal "$2 path '${_f}'"
    fi
    _f="$(_resolve "${_f}")"
    [[ -f "${_f}" && -r "${_f}" ]] \
        || hook_block "$2: cannot read the body file '$1' to check it (fail closed)." \
            "Write the body file in a separate step first, then pass it with a literal path."
    _text="$(cat -- "${_f}")"
    _judge "${_text}" "$2 file '$1'"
}

# _opt_values <name>... - every value of the given options in _E (from
# index 2 on), still encoded, NUL-terminated: -n x, -nx, -n=x, --name=x.
_opt_values() {
    local _i _n _w
    for ((_i = 2; _i < ${#_E[@]}; _i++)); do
        _w="${_E[_i]}"
        for _n in "$@"; do
            if [[ "${_w}" == "${_n}" ]]; then
                _i=$((_i + 1))
                printf '%s\0' "${_E[_i]:-}"
                break
            elif [[ "${_n}" == --* && "${_w}" == "${_n}="* ]]; then
                printf '%s\0' "${_w#*=}"
                break
            elif [[ "${_n}" == -? && "${_w}" == "${_n}"?* ]]; then
                _w="${_w#"${_n}"}"
                printf '%s\0' "${_w#=}"
                break
            fi
        done
    done
}

# _check_inline <source> <name>... - judge every inline value of the options.
_check_inline() {
    local _src="$1" _v
    shift
    while IFS= read -r -d '' _v; do
        _expands "${_v}" && _block_literal "${_src}"
        _judge "$(hook_word "${_v}")" "${_src}"
    done < <(_opt_values "$@")
    return 0
}

# _check_files <source> <name>... - judge every file the options name.
_check_files() {
    local _src="$1" _v
    shift
    while IFS= read -r -d '' _v; do
        hook_word_has_subst "${_v}" && _block_literal "${_src} path"
        _judge_file "$(hook_word "${_v}")" "${_src}"
    done < <(_opt_values "$@")
    return 0
}

# _check_api_fields - gh api -F / --field values: key=@file reads a file.
_check_api_fields() {
    local _v _w
    while IFS= read -r -d '' _v; do
        _expands "${_v}" && _block_literal "gh api field"
        _w="$(hook_word "${_v}")"
        if [[ "${_w}" == *=@* ]]; then
            _judge_file "${_w#*=@}" "gh api field"
        else
            _judge "${_w}" "gh api field"
        fi
    done < <(_opt_values -F --field)
    return 0
}

# _check_gh - judge the gh launch in _E (gh <group> <sub> ...).
_check_gh() {
    local _grp _sub
    _grp="$(hook_word "${_E[1]:-}")"
    _sub="$(hook_word "${_E[2]:-}")"
    if [[ "${_grp}" == api ]]; then
        _REL=1
        _check_inline "gh api field" -f --raw-field
        _check_api_fields
        _check_files "gh api --input" --input
        return 0
    fi
    [[ "${_grp}" == pr || "${_grp}" == issue ]] || return 0
    case "${_sub}" in
        create|new|comment|edit|review) ;;
        close|reopen) _REL=1; _check_inline "gh ${_grp} ${_sub} comment" --comment -c; return 0 ;;
        *) return 0 ;;
    esac
    _REL=1
    _check_inline "gh ${_grp} ${_sub} body" --body -b
    _check_files "gh ${_grp} ${_sub} body" --body-file -F
}

# _heredoc_bodies <command> - the lines of every heredoc body in <command>
# (the complement of lib/subcommand.sh's heredoc stripping).
_heredoc_bodies() {
    local _line _term='' _trim
    local _re="(^|[^<])<<-?[[:space:]]*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?"
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        if [[ -n "${_term}" ]]; then
            _trim="${_line#"${_line%%[![:space:]]*}"}"
            if [[ "${_trim}" == "${_term}" ]]; then _term=''; else printf '%s\n' "${_line}"; fi
            continue
        fi
        [[ "${_line}" =~ ${_re} ]] && _term="${BASH_REMATCH[2]}"
    done <<<"$1"
}

# _track_cd - follow a literal `cd <dir>` launch in _E for relative files.
_track_cd() {
    local _d
    _d="$(hook_word "${_E[1]:-}")"
    if [[ -z "${_d}" || "${_d}" == - ]] || _expands "${_E[1]}"; then
        _CWD=''
        return 0
    fi
    _CWD="$(_resolve "${_d}")"
}

main() {
    hook_read_input
    local _cmd _sub _here _w0
    _cmd="$(hook_command)"
    [[ -n "${_cmd}" ]] || hook_allow
    _CWD="$(hook_field '.cwd')"
    while IFS= read -r _sub; do
        read -r -a _E <<<"${_sub}"
        _w0="$(hook_word "${_E[0]:-}")"
        case "${_w0}" in
            cd) _track_cd ;;
            gh|*/gh) _check_gh ;;
        esac
    done < <(hook_subcommands_raw "${_cmd}")
    [[ "${_REL}" -eq 1 ]] || hook_allow
    _here="$(_heredoc_bodies "${_cmd}")"
    [[ "${_STDIN}" -eq 1 && -z "${_here}" ]] && _block_literal "a gh body read from stdin"
    _judge "${_here}" "a heredoc fed to gh"
    hook_allow
}

main "$@"
