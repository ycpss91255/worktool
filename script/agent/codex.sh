#!/usr/bin/env bash
# Launch Codex without the caller's GitHub authentication (issue #242).
set -euo pipefail

main() {
    local _help=0 _root _scratch _rc=0
    local -a _args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) _help=1; shift ;;
            --) shift; _args=("$@"); break ;;
            *) printf "codex.sh: unknown option '%s' (see --help)\n" "$1" >&2; return 2 ;;
        esac
    done
    if [[ "${_help}" -eq 1 ]]; then
        printf 'Usage: just agent codex [--help] -- <codex arguments...>\n'
        printf 'Launch Codex without GitHub tokens or the caller gh config.\n'
        return 0
    fi
    _root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
    mkdir -p "${_root}/.agents/state"
    _scratch="$(mktemp -d "${_root}/.agents/state/codex-no-gh.XXXXXX")"
    trap 'rm -rf -- "${_scratch}"' EXIT
    export CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
    export HOME="${_scratch}" GH_CONFIG_DIR="${_scratch}/gh" XDG_CONFIG_HOME="${_scratch}/config"
    unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
    codex "${_args[@]}" || _rc=$?
    rm -rf -- "${_scratch}"
    trap - EXIT
    return "${_rc}"
}

main "$@"
