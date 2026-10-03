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

check_tests() {
    local tool="$1" word skip=0 recipe='' text=''
    shift
    for word in "$@"; do
        text+=" $(hook_word "${word}")"
        [[ "${tool}" == just ]] || continue
        hook_word_has_expansion "${word}" && refuse 'Expanded just arguments cannot be checked.'
        word="$(hook_word "${word}")"
        if (( skip > 0 )); then
            skip=$((skip - 1))
            continue
        fi
        [[ -z "${recipe}" ]] || continue
        case "${word}" in
            -f|--justfile|-d|--working-directory|--chooser|--shell) skip=1 ;;
            --set) skip=2 ;;
            --*=*|-f?*|-d?*|--quiet|-q|--verbose|-v|--dry-run|-n|--) ;;
            -*) refuse 'Unknown just option cannot be checked.' ;;
            *) recipe="${word}" ;;
        esac
    done
    if [[ "${tool}" == just && "${recipe}" == test ]]; then
        refuse 'Main-session tests belong in a Workflow.'
    fi
    if [[ "${tool}" == docker && "${text}" =~ (^|[[:space:]\"\'])([^[:space:]\"\']*/)?bats([[:space:]\"\']|$) ]]; then
        refuse 'Main-session Docker bats execution belongs in a Workflow.'
    fi
}

check_launch() {
    local launch="$1" lead tool
    local -a words=()
    lead="$(hook_timeout_lead "${launch}")"
    read -r -a words <<<"${launch#"${lead}"}"
    tool="$(hook_word "${words[0]:-}")"
    if [[ "${tool##*/}" == git ]]; then
        check_git "${words[@]:1}"
    elif [[ "${tool##*/}" == just || "${tool##*/}" == docker ]]; then
        check_tests "${tool##*/}" "${words[@]:1}"
    fi
}

check_edit() {
    local cwd path common root
    cwd="$(hook_field '.cwd')"
    [[ -n "${cwd}" ]] || cwd="${HOOK_REPO_ROOT}"
    path="$(hook_field '.tool_input.file_path // .tool_input.notebook_path')"
    [[ -n "${path}" ]] || return 0
    [[ "${path}" == /* ]] || path="${cwd}/${path}"
    path="$(realpath -m -- "${path}")"
    if ! common="$(git -C "${cwd}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
        common="$(git -C "${HOOK_REPO_ROOT}" rev-parse --path-format=absolute --git-common-dir)"
    fi
    root="$(realpath -m -- "$(hook_worktree_root "$(dirname -- "${common}")")")"
    [[ "${path}" != "${root}" && "${path}" != "${root}/"* ]] || \
        refuse 'Main-session file edits under worktree/ belong in a Workflow.'
}

main() {
    hook_read_input
    local launch
    if [[ "$(hook_field '.tool_name')" == Bash ]]; then
        while IFS= read -r launch; do
            check_launch "${launch}"
        done < <(hook_subcommands_raw "$(hook_command)")
    elif [[ "$(hook_field '.tool_name')" =~ ^(Edit|Write|MultiEdit|NotebookEdit)$ ]]; then
        check_edit
    fi
    hook_allow
}

main "$@"
