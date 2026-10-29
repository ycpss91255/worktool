#!/usr/bin/env bash
# Inspect direct Bash launches only; never execute Ghostty or read script files.
# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-ghostty-gui"

_deny_gui() {
    hook_block 'Do not operate host graphical Ghostty or signal its processes.' \
        'Read documentation or source code, or test with a stub in Docker instead.'
}

_check_query() {
    local _word _action
    _action="$(hook_word "${1:-}")"
    case "${_action}" in
        --version|+help|+version|+show-config|+list-?*) ;;
        *) _deny_gui ;;
    esac
    shift
    for _word in "$@"; do
        hook_word_has_expansion "${_word}" && _deny_gui
        [[ "$(hook_word "${_word}")" != +* ]] || _deny_gui
    done
}

_check_signal() {
    local _encoded _word
    for _encoded in "$@"; do
        _word="$(hook_word "${_encoded}")"
        [[ "${_word,,}" != *ghostty* ]] || _deny_gui
        # PID substitutions lose their body in the shared launch parser.
        # A signal with an expansion and a Ghostty reference is ambiguous.
        if hook_word_has_expansion "${_encoded}" && [[ "${_command,,}" == *ghostty* ]]; then
            _deny_gui
        fi
    done
}

_check_launch() {
    local _launch="$1" _lead _exe
    local -a _words=()
    _lead="$(hook_timeout_lead "${_launch}")"
    _launch="$(_hook_strip_wrappers "${_launch#"${_lead}"}")"
    read -r -a _words <<<"${_launch}"
    _exe="$(hook_word "${_words[0]:-}")"
    case "${_exe##*/}" in
        ghostty) _check_query "${_words[@]:1}" ;;
        kill|pkill|killall) _check_signal "${_words[@]:1}" ;;
    esac
}

main() {
    hook_read_input
    local _launch _command
    _command="$(hook_command)"
    while IFS= read -r _launch; do
        _check_launch "${_launch}"
    done < <(hook_subcommands_raw "${_command}")
    hook_allow
}
main "$@"
