#!/usr/bin/env bash
# Main sessions coordinate; workflows perform implementation and tests.
# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-main-session-coordinates-only"

refuse() {
    hook_block "$1" 'Use pr-loop / milestone-fanout / milestone-handover.'
}

check_launch() {
    local launch="$1" lead tool
    local -a words=()
    lead="$(hook_timeout_lead "${launch}")"
    read -r -a words <<<"${launch#"${lead}"}"
    tool="$(hook_word "${words[0]:-}")"
    if [[ "${tool##*/}" == git ]]; then
        case "$(hook_word "${words[1]:-}")" in
            commit|merge|push) refuse 'Main-session git mutation belongs in a Workflow.' ;;
        esac
    fi
}

main() {
    hook_read_input
    local launch
    if [[ "$(hook_field '.tool_name')" == Bash ]]; then
        while IFS= read -r launch; do
            check_launch "${launch}"
        done < <(hook_subcommands_raw "$(hook_command)")
    fi
    hook_allow
}

main "$@"
