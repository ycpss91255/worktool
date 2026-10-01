#!/usr/bin/env bash
# Reserve expensive local test launches for CI; inspect launches, not text.
# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-local-test-scope"

_heavy_test() {
    local _launch="$1" _word _lead
    local -a _encoded=() _words=()
    _lead="$(hook_timeout_lead "${_launch}")"
    _launch="$(_hook_strip_wrappers "${_launch#"${_lead}"}")"
    read -r -a _encoded <<<"${_launch}"
    for _word in "${_encoded[@]}"; do _words+=("$(hook_word "${_word}")"); done
    case "${_words[0]:-}" in
        bash|sh|*/bash|*/sh) _words=("${_words[@]:1}") ;;
    esac
    case "${_words[0]:-}" in
        just|*/just)
            [[ "${_words[1]:-}" == test ]] || return 1
            _words=("${_words[@]:2}") ;;
        script/test/test.sh|*/script/test/test.sh) _words=("${_words[@]:1}") ;;
        *) return 1 ;;
    esac
    [[ "${#_words[@]}" -gt 0 ]] || return 0
    for _word in "${_words[@]}"; do
        case "${_word}" in
            matrix|integration|system|system-real|acceptance|--matrix|--integration|--system|--system-real|--acceptance) return 0 ;;
            unit|--unit) _has_spec "${_words[@]:1}" || return 0 ;;
        esac
    done
    return 1
}

_has_spec() {
    local _arg _filter=''
    for _arg in "$@"; do
        if [[ -n "${_filter}" ]]; then
            _filter=''
            continue
        fi
        case "${_arg}" in
            --filter) _filter=1 ;;
            --filter=*|-*) ;;
            */*.bats) return 0 ;;
        esac
    done
    return 1
}

main() {
    hook_read_input
    local _launch
    while IFS= read -r _launch; do
        if _heavy_test "${_launch}"; then
            hook_block 'This tier is verified by CI (ci-passed).' \
                'Locally run only lint and changed unit specs: just test lint; just test unit <spec...> [--filter REGEX].'
        fi
    done < <(hook_subcommands_raw "$(hook_command)")
    hook_allow
}
main "$@"
