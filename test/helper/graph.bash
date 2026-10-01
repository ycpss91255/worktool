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
#   graph_judges <tree> <function>
#                                 every script under script/ that calls
#                                 <function>, directly or through functions
#                                 of the modules in its source graph
#   graph_touches_config <tree> <file>
#                                 0 when <file> (not lib/config.sh itself)
#                                 names a public lib/config.sh function (every
#                                 `config_*()` it defines) or XDG_CONFIG_HOME
#                                 in a non-comment line
#
# Resolution: `${...LIB_DIR}/<x>`, `${...}/lib/<x>` and script-relative
# `${SCRIPT_DIR}/../../lib/<x>` are <tree>/lib/<x> -
# the forms the scripts and libraries use (LIB_DIR is the repo's lib/,
# a library's own `_<NAME>_LIB_DIR` is its directory, which is lib/).

_graph_target() {
    local _a="${1#\"}"
    _a="${_a%\"}"
    case "${_a}" in
        '${SCRIPT_DIR}/../../lib/'*) printf 'lib/%s\n' "${_a##*/lib/}" ;;
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

# The owner guards first select source graphs reaching lib/config.sh,
# then check only the modules this accepts: a module that names neither a public config_* function nor
# XDG_CONFIG_HOME outside comments is not checked.
graph_touches_config() {
    local _api
    [[ "$2" != lib/config.sh ]] || return 1
    # The public API: every `config_*()` lib/config.sh defines.
    _api="$(sed -n 's/^\(config_[a-z_]*\)() .*/\1/p' "$1/lib/config.sh" | paste -sd'|')"
    grep -v '^[[:space:]]*#' "$1/$2" | grep -qE "\b(${_api})\b|XDG_CONFIG_HOME"
}

# The functions defined in file $2 of tree $1, one `<name>\t<body>` line
# each (body lines joined by spaces, comment lines dropped).
_graph_functions() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ {
            fn = $0; sub(/\(.*/, "", fn); body = $0
            if ($0 ~ /\}[[:space:]]*$/) { print fn "\t" body; fn = "" }
            next
        }
        fn != "" { body = body " " $0 }
        fn != "" && /^\}/ { print fn "\t" body; fn = "" }
    ' "$1/$2"
}

# The scripts under script/ (repo-relative, one per line) that call
# function $2 of tree $1 - directly, or through any chain of functions
# defined in the modules of their source graph: a script is listed when a
# function it defines is in that call closure.
graph_judges() {
    local _tree="$1" _s _m _mods _defs _name _body _changed _f
    local -A _in=()
    for _s in "${_tree}"/script/*/*.sh; do
        _s="${_s#"${_tree}"/}"
        _mods="$(graph_modules "${_tree}" "${_s}")" || return 1
        _defs="$(while IFS= read -r _m; do _graph_functions "${_tree}" "${_m}"; done <<<"${_mods}")"
        _in=([$2]=1)
        _changed=1
        while (( _changed )); do
            _changed=0
            while IFS=$'\t' read -r _name _body; do
                [[ -n "${_name}" && -z "${_in[${_name}]:-}" ]] || continue
                for _f in "${!_in[@]}"; do
                    if [[ " ${_body} " =~ [^A-Za-z0-9_]${_f}[^A-Za-z0-9_] ]]; then
                        _in[${_name}]=1
                        _changed=1
                        break
                    fi
                done
            done <<<"${_defs}"
        done
        while IFS=$'\t' read -r _name _body; do
            if [[ -n "${_in[${_name}]:-}" ]]; then
                printf '%s\n' "${_s}"
                break
            fi
        done < <(_graph_functions "${_tree}" "${_s}")
    done
}
