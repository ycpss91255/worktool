#!/usr/bin/env bash
# Guard signals and clean up new window shells for Bash text mentioning Ghostty.
# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
# shellcheck source=ghostty_windows.sh
source "${_HOOK_HERE}/lib/ghostty_windows.sh"
hook_bootstrap "enforce-ghostty-gui"

_deny_gui() {
    hook_block 'Do not signal host Ghostty processes; this affects all windows.' \
        'Read documentation or source code, or test with a stub in Docker instead.'
}

_check_signal() {
    local _encoded _word
    for _encoded in "$@"; do
        _word="$(hook_word "${_encoded}")"
        [[ "${_word,,}" != *ghostty* ]] || _deny_gui
        if [[ "${_exe##*/}" == kill && "${_word}" =~ ^[0-9]+$ ]]; then
            local _processes
            _processes="$(ghostty_processes_read)"
            if jq -e --arg pid "${_word}" 'any(.[];
                .pid == $pid and (.comm | ascii_downcase) == "ghostty")' \
                <<<"${_processes}" >/dev/null; then
                _deny_gui
            fi
        fi
        # PID substitutions lose their body in the shared launch parser.
        # Fail closed when a PID lookup and an expanded signal target coexist.
        if hook_word_has_expansion "${_encoded}" && [[ "${_ghostty_lookup}" == 1 ]]; then
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
    if [[ "${_exe}" == builtin && "$(hook_word "${_words[1]:-}")" == kill ]]; then
        _words=("${_words[@]:1}")
        _exe='kill'
    fi
    if [[ "${2:-}" == lookup ]]; then
        case "${_exe##*/}" in
            pgrep|pidof|ps)
                local _word
                for _word in "${_words[@]:1}"; do
                    _word="$(hook_word "${_word}")"
                    [[ "${_word,,}" != *ghostty* ]] || _ghostty_lookup=1
                done ;;
        esac
        return 0
    fi
    case "${_exe##*/}" in
        kill|pkill|killall) _check_signal "${_words[@]:1}" ;;
    esac
}

main() {
    hook_read_input
    if ! jq -e 'type == "object" and
        (.tool_input.command == null or (.tool_input.command | type == "string"))' \
        <<<"${HOOK_INPUT}" >/dev/null 2>&1; then
        hook_block 'Cannot read the Bash command payload (fail closed).' \
            'Provide a literal command; use documentation, source code or Docker stubs for Ghostty.'
    fi
    if [[ "$(hook_field '.hook_event_name')" =~ ^PostToolUse(Failure)?$ ]]; then
        ghostty_windows_track
        hook_allow
    fi
    local _launch _command _launches _ghostty_lookup=0
    _command="$(hook_command)"
    _launches="$(hook_subcommands_raw "${_command}")" || _deny_gui
    while IFS= read -r _launch; do
        _check_launch "${_launch}" lookup
    done <<<"${_launches}"
    while IFS= read -r _launch; do
        _check_launch "${_launch}"
    done <<<"${_launches}"
    ghostty_windows_track
    hook_allow
}
main "$@"
