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

_check_launch() {
    local _launch="$1" _lead _exe
    local -a _words=()
    _lead="$(hook_timeout_lead "${_launch}")"
    _launch="$(_hook_strip_wrappers "${_launch#"${_lead}"}")"
    read -r -a _words <<<"${_launch}"
    _exe="$(hook_word "${_words[0]:-}")"
    case "${_exe##*/}" in
        ghostty) _deny_gui ;;
    esac
}

main() {
    hook_read_input
    local _launch
    while IFS= read -r _launch; do
        _check_launch "${_launch}"
    done < <(hook_subcommands_raw "$(hook_command)")
    hook_allow
}
main "$@"
