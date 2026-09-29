#!/usr/bin/env bash
# test/helper/graph.bash - the source graph of worktool's scripts (issue #199
# round 8), for the ownership specs.
#
# Loaded by test/unit/config_owner_spec.bats and
# test/unit/config_mutation_spec.bats after helper/common (REPO_ROOT).
#
#   graph_modules <tree> <file>   every file <file> reaches by `source` / `.`
#                                 lines, itself included, repo-relative, one
#                                 per line (breadth first). A source line it
#                                 cannot resolve is reported on stderr and
#                                 returns 1: an unknown pattern fails the
#                                 guards instead of hiding a module.
#   graph_touches_config <tree> <file>
#                                 0 when <file> (not lib/config.sh itself)
#                                 names a public lib/config.sh function (every
#                                 `config_*()` it defines) or XDG_CONFIG_HOME
#                                 in a non-comment line
#
# Resolution: `${...LIB_DIR}/<x>` and `${...}/lib/<x>` are <tree>/lib/<x> -
# the two forms the scripts and libraries use (LIB_DIR is the repo's lib/,
# a library's own `_<NAME>_LIB_DIR` is its directory, which is lib/).

_graph_target() {
    local _a="${1#\"}"
    _a="${_a%\"}"
    case "${_a}" in
        '${'*'LIB_DIR}/'*) printf 'lib/%s\n' "${_a#*\}/}" ;;
        '${'*'}/lib/'*) printf 'lib/%s\n' "${_a##*/lib/}" ;;
        *) return 1 ;;
    esac
}

graph_modules() {
    local _tree="$1" _f _line _t
    local -a _queue=("$2")
    local -A _seen=()
    while (( ${#_queue[@]} > 0 )); do
        _f="${_queue[0]}"
        _queue=("${_queue[@]:1}")
        [[ -z "${_seen[${_f}]:-}" ]] || continue
        _seen[${_f}]=1
        printf '%s\n' "${_f}"
        while IFS= read -r _line; do
            [[ "${_line}" =~ ^[[:space:]]*(source|\.)[[:space:]]+([^[:space:]]+) ]] || continue
            if ! _t="$(_graph_target "${BASH_REMATCH[2]}")"; then
                printf 'unresolved source line in %s: %s\n' "${_f}" "${_line}" >&2
                return 1
            fi
            _queue+=("${_t}")
        done <"${_tree}/${_f}"
    done
}

# The owner guards check only the modules this accepts: a module of the
# source graph that names neither a public config_* function nor
# XDG_CONFIG_HOME outside comments is not checked.
graph_touches_config() {
    local _api
    [[ "$2" != lib/config.sh ]] || return 1
    # The public API: every `config_*()` lib/config.sh defines.
    _api="$(sed -n 's/^\(config_[a-z_]*\)() .*/\1/p' "$1/lib/config.sh" | paste -sd'|')"
    grep -v '^[[:space:]]*#' "$1/$2" | grep -qE "\b(${_api})\b|XDG_CONFIG_HOME"
}
