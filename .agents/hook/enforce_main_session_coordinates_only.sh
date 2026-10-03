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

check_git() {
    local word sub='' skip='' ff='' conflict=''
    local -a args=()
    for word in "$@"; do
        hook_word_has_expansion "${word}" && refuse 'Expanded git arguments cannot be checked.'
        word="$(hook_word "${word}")"
        if [[ -n "${sub}" ]]; then
            args+=("${word}")
        elif [[ -n "${skip}" ]]; then
            skip=''
        else
            case "${word}" in
                -C|-c|--git-dir|--work-tree|--namespace|--config-env) skip=1 ;;
                -C?*|-c?*|--git-dir=*|--work-tree=*|--namespace=*|--config-env=*) ;;
                --no-pager|--paginate|--literal-pathspecs|--no-optional-locks) ;;
                -*) refuse 'Unknown git root option cannot be checked.' ;;
                *) sub="${word}" ;;
            esac
        fi
    done
    case "${sub}" in
        commit|merge|rebase|push|cherry-pick|revert|am|reset|restore|stash|apply)
            refuse 'Main-session git mutation belongs in a Workflow.' ;;
        checkout)
            for word in "${args[@]}"; do
                [[ "${word}" != -- ]] || refuse 'Main-session git path checkout belongs in a Workflow.'
            done ;;
        pull)
            for word in "${args[@]}"; do
                [[ "${word}" != --ff-only ]] || ff=1
                case "${word}" in --no-ff|--ff|--rebase*|--no-rebase) conflict=1 ;; esac
            done
            [[ -n "${ff}" && -z "${conflict}" ]] || refuse 'Only git pull --ff-only is allowed.' ;;
    esac
}

check_launch() {
    local launch="$1" lead tool
    local -a words=()
    lead="$(hook_timeout_lead "${launch}")"
    read -r -a words <<<"${launch#"${lead}"}"
    tool="$(hook_word "${words[0]:-}")"
    if [[ "${tool##*/}" == git ]]; then
        check_git "${words[@]:1}"
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
