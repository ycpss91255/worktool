#!/usr/bin/env bash
# Keep a repository's main checkout read-only; changes belong in worktrees.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-main-checkout-readonly"

_absolute_path() {
    local _path="$1" _cwd="$2"
    [[ "${_path}" == /* ]] || _path="${_cwd}/${_path}"
    realpath -m -- "${_path}"
}

_existing_parent() {
    local _path="$1"
    while [[ ! -d "${_path}" && "${_path}" != / ]]; do
        _path="${_path%/*}"
        [[ -n "${_path}" ]] || _path=/
    done
    printf '%s\n' "${_path}"
}

_repo_paths() {
    local _dir="$1" _top _git _common
    _top="$(git -C "${_dir}" rev-parse --show-toplevel 2>/dev/null)" || return 1
    _git="$(git -C "${_dir}" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
    _common="$(git -C "${_dir}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    printf '%s\n%s\n%s\n' "$(realpath -m -- "${_top}")" "$(realpath -m -- "${_git}")" "$(realpath -m -- "${_common}")"
}

_block_edit_if_main() {
    local _path="$1" _cwd="$2" _parent _top _git _common
    local -a _repo=()
    _path="$(_absolute_path "${_path}" "${_cwd}")"
    _parent="$(_existing_parent "${_path}")"
    mapfile -t _repo < <(_repo_paths "${_parent}")
    [[ "${#_repo[@]}" -eq 3 ]] || return 0
    _top="${_repo[0]}" _git="${_repo[1]}" _common="${_repo[2]}"
    [[ "${_git}" == "${_common}" ]] || return 0
    [[ "${_path}" == "${_top}" || "${_path}" == "${_top}/"* ]] || return 0
    [[ "${_path}" != "${_top}/.worktree/"* ]] || return 0
    [[ "${_path}" != "${_top}/.agents/memory/"* ]] || return 0
    hook_block "file edit targets the main checkout: ${_path}" \
        "Create or reuse a linked worktree and make the change there."
}

_git_context() {
    local _cwd="$1" _word _next='' _seen=0
    shift
    GIT_ARGS=()
    for _word in "$@"; do
        if [[ "${_next}" == cwd ]]; then
            [[ "${_word}" == /* ]] || _word="${_cwd}/${_word}"
            _cwd="$(realpath -m -- "${_word}")" _next=''
        elif [[ -n "${_next}" ]]; then
            _next=''
        elif (( _seen == 1 )); then
            GIT_ARGS+=("${_word}")
        elif [[ "${_word}" == -C ]]; then
            _next=cwd
        elif [[ "${_word}" == -C?* ]]; then
            _word="${_word#-C}"
            [[ "${_word}" == /* ]] || _word="${_cwd}/${_word}"
            _cwd="$(realpath -m -- "${_word}")"
        elif [[ "${_word}" =~ ^(-c|--config-env|--exec-path|--git-dir|--work-tree|--namespace|--super-prefix)$ ]]; then
            _next=value
        elif [[ "${_word}" == -* ]]; then
            continue
        else
            GIT_ARGS+=("${_word}") _seen=1
        fi
    done
    GIT_CWD="${_cwd}"
}

_checkout_mutates() {
    local _arg
    shift
    (( $# > 0 )) || return 1
    for _arg in "$@"; do
        [[ "${_arg}" != -- ]] || return 0
        [[ "${_arg}" != -* ]] || return 0
    done
    [[ "$1" != main || $# -ne 1 ]]
}

_git_mutates() {
    local _sub="${1:-}"
    case "${_sub}" in
        commit|merge|rebase|reset|cherry-pick|revert|am|apply|restore|clean) return 0 ;;
        stash) [[ "${2:-}" == pop || "${2:-}" == apply ]] ;;
        checkout|switch) _checkout_mutates "$@" ;;
        pull)
            local _arg
            for _arg in "${@:2}"; do [[ "${_arg}" == --ff-only ]] && return 1; done
            return 0 ;;
        worktree)
            case "${2:-}" in add|remove|prune|list) return 1 ;; *) return 0 ;; esac ;;
        *) return 1 ;;
    esac
}

_main_checkout() {
    local -a _repo=()
    mapfile -t _repo < <(_repo_paths "$1")
    [[ "${#_repo[@]}" -eq 3 && "${_repo[1]}" == "${_repo[2]}" ]]
}

_check_git_launch() {
    local _launch="$1" _cwd="$2" _encoded _word
    local -a _words=()
    read -r -a _encoded <<<"${_launch}"
    for _word in "${_encoded[@]}"; do _words+=("$(hook_word "${_word}")"); done
    [[ "${_words[0]:-}" == git || "${_words[0]:-}" == */git ]] || return 0
    _git_context "${_cwd}" "${_words[@]:1}"
    _git_mutates "${GIT_ARGS[@]}" || return 0
    _main_checkout "${GIT_CWD}" || return 0
    hook_block "git ${GIT_ARGS[0]} would modify the main checkout: ${GIT_CWD}" \
        "Run mutating git commands in a linked worktree."
}

_check_bash() {
    local _command="$1" _cwd="$2" _launch
    while IFS= read -r _launch; do
        [[ -n "${_launch}" ]] || continue
        _check_git_launch "${_launch}" "${_cwd}"
    done < <(hook_subcommands_raw "${_command}")
}

main() {
    hook_read_input
    local _tool _cwd _path
    _tool="$(hook_field '.tool_name')"
    _cwd="$(hook_field '.cwd')"
    [[ -n "${_cwd}" ]] || _cwd="${HOOK_REPO_ROOT}"
    if [[ "${_tool}" == Bash ]]; then
        _check_bash "$(hook_command)" "${_cwd}"
    elif [[ "${_tool}" =~ ^(Edit|Write|MultiEdit|NotebookEdit)$ ]]; then
        _path="$(hook_field '.tool_input.file_path // .tool_input.notebook_path')"
        [[ -z "${_path}" ]] || _block_edit_if_main "${_path}" "${_cwd}"
    fi
    hook_allow
}

main "$@"
