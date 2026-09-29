#!/usr/bin/env bash
# .agents/hook/lib/subcommand.sh - split a Bash command line into the
# sub-commands it actually launches, for the PreToolUse Bash hooks.
#
# A hook that pattern-matches the raw command text blocks commit messages,
# PR bodies and files being written just because they MENTION a trigger
# word. This lib reduces the text to launches, so a hook can judge each
# one by its first word:
#
#   hook_subcommands <command>   one sub-command per line on stdout:
#     1. heredoc bodies are dropped (a here-string `<<<` is not a heredoc)
#     2. quoted spans ('...' and "...", per line) are dropped
#     3. the rest is split on ; && || | and newlines
#     4. leading VAR=val assignments and sudo / env / command / time /
#        nohup / exec wrappers are stripped; timeout(1) is kept, since the
#        long-job hook treats it as a bound
#     5. pieces are trimmed; empty ones are dropped
#
# Deliberately simple (no full shell parser): nested or escaped quotes and
# multi-line quoted arguments degrade to "some text leaks through", which
# the calling hooks accept.
#
# Library: sourced, sets no shell options, only declares functions.

# Library guard: refuse to run as an executable script.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf 'Warn: %s is a library, not an executable script.\n' "${BASH_SOURCE[0]##*/}"
    return 0 2>/dev/null
fi

# _hook_strip_heredocs <command> - the command minus every heredoc body. A
# line opening a heredoc (`<<WORD`, `<<-WORD`, `<<'WORD'`, `<<"WORD"`, not
# `<<<`) is kept; the lines up to the terminator line WORD (leading blanks
# allowed, for <<-) are dropped.
_hook_strip_heredocs() {
    local _line _term='' _trim
    local _re="(^|[^<])<<-?[[:space:]]*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?"
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        if [[ -n "${_term}" ]]; then
            _trim="${_line#"${_line%%[![:space:]]*}"}"
            [[ "${_trim}" == "${_term}" ]] && _term=''
            continue
        fi
        printf '%s\n' "${_line}"
        if [[ "${_line}" =~ ${_re} ]]; then
            _term="${BASH_REMATCH[2]}"
        fi
    done <<<"$1"
}

# _hook_strip_wrappers <sub-command> - drop leading assignments and the
# pass-through wrappers until nothing more changes.
_hook_strip_wrappers() {
    local _sub="$1" _before
    while :; do
        _before="${_sub}"
        _sub="${_sub#"${_sub%%[![:space:]]*}"}"
        if [[ "${_sub}" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*([[:space:]]|$) ]]; then
            _sub="${_sub#"${BASH_REMATCH[0]}"}"
        else
            case "${_sub}" in
                sudo[[:space:]]*|env[[:space:]]*|command[[:space:]]*|time[[:space:]]*|nohup[[:space:]]*|exec[[:space:]]*)
                    _sub="${_sub#*[[:space:]]}" ;;
            esac
        fi
        [[ "${_sub}" == "${_before}" ]] && break
    done
    printf '%s' "${_sub}"
}

# hook_subcommands <command> - see the header.
hook_subcommands() {
    local _text _sub
    _text="$(_hook_strip_heredocs "$1" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")"
    _text="${_text//&&/$'\n'}"
    _text="${_text//||/$'\n'}"
    _text="${_text//;/$'\n'}"
    _text="${_text//|/$'\n'}"
    while IFS= read -r _sub; do
        _sub="$(_hook_strip_wrappers "${_sub}")"
        _sub="${_sub%"${_sub##*[![:space:]]}"}"
        [[ -n "${_sub}" ]] && printf '%s\n' "${_sub}"
    done <<<"${_text}"
    return 0
}
