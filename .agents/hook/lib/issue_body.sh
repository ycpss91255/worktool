#!/usr/bin/env bash
# .agents/hook/lib/issue_body.sh - read the body a `gh issue create` launch
# files, for the PreToolUse Bash hooks that judge an issue by its body
# (enforce_scope_on_guard_issues, enforce_issue_milestone).
#
#   hook_read_body_file <path>     print a --body-file; a relative path is
#     resolved against the tool call's cwd (hook_field '.cwd'). Exit 1 when
#     the file cannot be read.
#   hook_issue_stdin_body <command>   the stdin body (-F - / --body-file -)
#     fed to the ONE gh issue create launch of <command>, found with quotes
#     masked and a # comment cut off: a heredoc opened on the launch line
#     itself (`gh issue create ... -F - <<'EOF'`), or one file piped into it
#     by a plain cat (`cat body.md | gh issue create ... -F -`). Nothing when
#     it cannot be seen: any other pipe, a < file, 2<<, a heredoc of another
#     command, a comment, or two gh issue create launches in <command>.
#
# Needs hook_bootstrap.sh sourced first (hook_field).
#
# Library: sourced, sets no shell options, only declares functions.

# Library guard: refuse to run as an executable script.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf 'Warn: %s is a library, not an executable script.\n' "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# hook_read_body_file <path> - print the file, relative to the tool call's cwd.
hook_read_body_file() {
    local _p="$1" _cwd
    if [[ "${_p}" != /* ]]; then
        _cwd="$(hook_field '.cwd')"
        _p="${_cwd:-${PWD}}/${_p}"
    fi
    [[ -r "${_p}" ]] || return 1
    cat -- "${_p}"
}

# _ib_mask_line <line> - the line with every quoted character (and the escaped
# character after a backslash) replaced by '_' and an unquoted # comment cut
# off, so offsets still line up with the line. Exit 1 when the line ends
# inside an open quote.
_ib_mask_line() {
    local _l="$1" _m='' _q='' _c _i _p=' ' _sep=$' \t;&|()'
    for ((_i = 0; _i < ${#_l}; _i++)); do
        _c="${_l:_i:1}"
        if [[ "${_c}" == "\\" && "${_q}" != "'" ]]; then
            _m+='__'
            _i=$((_i + 1))
            _p='_'
            continue
        fi
        if [[ -n "${_q}" ]]; then
            if [[ "${_c}" == "${_q}" ]]; then _q='' _m+="${_c}"; else _m+='_'; fi
        elif [[ "${_c}" == "'" || "${_c}" == '"' ]]; then
            _q="${_c}" _m+="${_c}"
        elif [[ "${_c}" == '#' && "${_sep}" == *"${_p}"* ]]; then
            break
        else
            _m+="${_c}"
        fi
        _p="${_c}"
    done
    printf '%s' "${_m:0:${#_l}}"
    [[ -z "${_q}" ]]
}

# _ib_heredoc_op <line> <mask> - "<offset> <dash> <word>" of the first heredoc
# the line opens (<<WORD, <<-WORD, <<'WORD', <<"WORD"; not <<<), located on
# the mask, the word read from the line; nothing when it opens none.
_ib_heredoc_op() {
    local _pre="${2%%<<*}"
    [[ "${_pre}" != "$2" && "${2:${#_pre}:3}" != '<<<' ]] || return 0
    [[ "${1:${#_pre}}" =~ ^\<\<(-?)[[:space:]]*[\'\"]?([A-Za-z_][A-Za-z0-9_]*) ]] || return 0
    printf '%s %s %s' "${#_pre}" "${BASH_REMATCH[1]:-+}" "${BASH_REMATCH[2]}"
}

# _ib_gh_heredoc <mask> <op offset> - 0 when the heredoc at <op offset> is the
# stdin of the gh issue create launch on the line: it follows the launch,
# sits on fd 0, and no other < redirect on the launch replaces it.
_ib_gh_heredoc() {
    local _re='(^|[[:space:];&|(])gh[[:space:]]+issue[[:space:]]+create([[:space:]].*)$'
    [[ "$1" =~ ${_re} ]] || return 1
    local _at=$((${#1} - ${#BASH_REMATCH[2]})) _rest="${BASH_REMATCH[2]/<</}"
    [[ "$2" -gt "${_at}" && "${_rest}" != *'<'* ]] || return 1
    [[ "${1:$2-1:1}" == [[:space:]] || "${1:$2-2:2}" =~ ^[[:space:]]0$ ]]
}

# _ib_cat_pipe_file <line> <mask> - the file a plain `cat <one file> |` pipes
# into the gh issue create launch on the line, when nothing on the launch
# redirects its stdin again; nothing otherwise (an expansion or a glob in
# the file word is not resolved, so it yields nothing).
_ib_cat_pipe_file() {
    local _re='(^|[;&(|])([[:space:]]*cat[[:space:]]+)([^[:space:];&|()<>]+)'
    _re+='[[:space:]]*\|[[:space:]]*gh[[:space:]]+issue[[:space:]]+create(([[:space:]].*)?)$'
    [[ "$2" =~ ${_re} && "${BASH_REMATCH[4]}" != *'<'* ]] || return 0
    local _at=$((${#2} - ${#BASH_REMATCH[0]} + ${#BASH_REMATCH[1]} + ${#BASH_REMATCH[2]}))
    local _word="${1:_at:${#BASH_REMATCH[3]}}"
    [[ "${_word}" != *[\$\`\\*?~]* ]] || return 0
    _word="${_word//\'/}"
    printf '%s' "${_word//\"/}"
}

# hook_issue_stdin_body <command> - the stdin body fed to the one gh issue create
# launch of the command (see the header); nothing when it cannot be seen.
hook_issue_stdin_body() {
    local _line _mask _op _term='' _dash='' _mine=0 _hits=0 _body='' _src=''
    local _gh='(^|[[:space:];&|(])gh[[:space:]]+issue[[:space:]]+create([[:space:]]|$)'
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        if [[ -n "${_term}" ]]; then
            [[ "${_dash}" == '-' ]] && _line="${_line#"${_line%%[!$'\t']*}"}"
            if [[ "${_line}" == "${_term}" ]]; then _term=''; continue; fi
            [[ "${_mine}" -eq 1 ]] && _body+="${_line}"$'\n'
            continue
        fi
        _mask="$(_ib_mask_line "${_line}")" || return 0
        _mine=0
        _op="$(_ib_heredoc_op "${_line}" "${_mask}")"
        if [[ "${_mask}" =~ ${_gh} ]]; then
            _hits=$((_hits + 1))
            [[ -n "${_op}" ]] && _ib_gh_heredoc "${_mask}" "${_op%% *}" && _mine=1
            _src="$(_ib_cat_pipe_file "${_line}" "${_mask}")"
        fi
        [[ -n "${_op}" ]] && read -r _ _dash _term <<<"${_op}"
    done <<<"${1//\\$'\n'/}"
    [[ "${_hits}" -eq 1 ]] || return 0
    printf '%s' "${_body}"
    [[ -n "${_src}" ]] && hook_read_body_file "${_src}"
    return 0
}
