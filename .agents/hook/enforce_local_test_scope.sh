#!/usr/bin/env bash
# Reserve expensive local test launches for CI; inspect launches, not text.
# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-local-test-scope"

# ADR 0014 decision 2: lint plus the touched specs of any tier run locally;
# a whole tier, the real-engine group and every-tier runs are left to CI.
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
            _words=("${_words[@]:2}")
            # A just test recipe forwards to the test.sh flag of its name.
            if [[ "${#_words[@]}" -gt 0 && "${_words[0]}" != -* ]]; then
                _words[0]="--${_words[0]}"
            fi ;;
        script/test/test.sh|*/script/test/test.sh) _words=("${_words[@]:1}") ;;
        *) return 1 ;;
    esac
    _out_of_scope "${_words[@]}"
}

# _out_of_scope <test.sh argv> - 0 when the run leaves the local scope.
_out_of_scope() {
    local _arg _value='' _tiers=0 _specs=0
    for _arg in "$@"; do
        if [[ -n "${_value}" ]]; then _value=''; continue; fi
        case "${_arg}" in
            --filter|--base) _value=1 ;;
            --help|-h|--changed) return 1 ;;
        esac
    done
    [[ "$#" -gt 0 ]] || return 0
    for _arg in "$@"; do
        if [[ -n "${_value}" ]]; then _value=''; continue; fi
        case "${_arg}" in
            --filter|--base) _value=1 ;;
            --build|--lint|--guards|--ci-lint) ;;
            --system-real|--ci-system-real|--ci-integration-ghostty) return 0 ;;
            --unit|--matrix|--integration|--system|--acceptance) _tiers=$((_tiers + 1)) ;;
            --ci-unit|--ci-matrix|--ci-integration|--ci-system|--ci-acceptance) _tiers=$((_tiers + 1)) ;;
            test/system-real/*|*/test/system-real/*|*/real_engine_spec.bats|real_engine_spec.bats) return 0 ;;
            */*.bats) _specs=$((_specs + 1)) ;;
        esac
    done
    if [[ "${_tiers}" -eq 0 ]] || [[ "${_tiers}" -eq 1 && "${_specs}" -gt 0 ]]; then
        return 1
    fi
    return 0
}

main() {
    hook_read_input
    local _launch
    while IFS= read -r _launch; do
        if _heavy_test "${_launch}"; then
            hook_block 'A whole tier, the real-engine group and every-tier runs are verified by CI (ci-passed).' \
                'ADR 0014 decision 2: locally run just test lint plus the specs you touched, in any tier except system-real: just test <tier> <spec...> [--filter REGEX].'
        fi
    done < <(hook_subcommands_raw "$(hook_command)")
    hook_allow
}
main "$@"
