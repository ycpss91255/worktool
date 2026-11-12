#!/usr/bin/env bash
# test/helper/verify_tools.bash - the tools each acceptance item's
# precondition checks require, derived from the verify scripts (issue #771),
# so the tool list in doc/acceptance.md is compared with the code instead of
# with a second hand-written list.
#
# Loaded by test/unit/acceptance_tools_spec.bats after helper/common
# (REPO_ROOT) and helper/graph (graph_modules, _graph_functions).
#
#   verify_item_tools <tree> <script>...
#                                 one `<tool>\t<item>` line per tool an item
#                                 of the given scripts (repo-relative)
#                                 requires, sorted and unique; returns 1
#                                 (with a reason on stderr) when a script's
#                                 graph cannot be resolved or a script yields
#                                 no item at all, so a broken derivation
#                                 fails the case instead of comparing
#                                 against nothing.
#
# An item's entry points, per script:
#   - every case arm `<id>) <function> ;;` (setup, diagram, realbox
#     dispatchers and realbox's first-item preflight);
#   - every case arm `<id>) printf '<word>\n' ;;` (ui and gate _item_fn /
#     _item_group), as <word> and as the group check _preconditions_<word>;
#   - `item_<id with _>` for every id of an `<NAME>_ITEMS=(...)` array
#     (evidence.sh dispatches by that name).
# Words that name no defined function are ignored. From the entry points the
# derivation follows every defined function a body names (the call closure
# over the script's source graph) and collects the literal tool names given
# to guard_require, _require_tools, _require_tool and _resolve_exec, the
# words of a `for <v> in ...` loop whose body calls `_resolve_exec "${<v>}"`,
# and `type -P <tool>`. One dispatcher is not followed as a whole:
# _cleanup_run runs one arm per token, so a `_cleanup_push <token>` follows
# that arm only (otherwise every item would reach every item's cleanup).
# An item that runs another item of the same script as a child process
# (`bash "${SCRIPT_DIR}/<script>" ... <id>`, as 5.4 runs 5.1) also requires
# that item's tools, so the child id's entry points join the closure
# (issue #782).

# The `<id>\t<entry word>` lines of script $2 in tree $1.
_verify_item_entries() {
    local _f="$1/$2" _ids _id _cases
    _cases="$(sed -nE \
        -e "s/^[[:space:]]+([0-9]+(\.[0-9]+)+)\)[[:space:]]+printf '([A-Za-z_][A-Za-z0-9_]*)\\\\n'[[:space:]]*;;.*/\1\t\3/p" \
        -e 's/^[[:space:]]+([0-9]+(\.[0-9]+)+)\)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*;;.*/\1\t\3/p' \
        "${_f}")"
    printf '%s\n' "${_cases}"
    _ids="$(sed -nE 's/^[A-Z_]*ITEMS=\(([0-9. ]+)\)$/\1/p' "${_f}")"
    for _id in ${_ids}; do
        if ! grep -qE "^${_id//./\.}"$'\t' <<<"${_cases}"; then
            printf '%s\titem_%s\n' "${_id}" "${_id//./_}"
        fi
    done
}

# Both brace and subshell function bodies are valid item entry points.
_verify_functions() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[A-Za-z_][A-Za-z0-9_]*\(\) *[{(]/ {
            fn = $0; sub(/\(.*/, "", fn); body = $0
            closing = $0 ~ /\(\) *\(/ ? "\\)" : "}"
            if ($0 ~ (closing "[[:space:]]*$")) { print fn "\t" body; fn = "" }
            next
        }
        fn != "" { body = body " " $0 }
        fn != "" && $0 ~ ("^" closing) { print fn "\t" body; fn = "" }
    ' "$1/$2"
}

# The literal tools named by the precondition calls in function body $1.
_verify_body_tools() {
    local _body="$1" _call _var _words
    while IFS= read -r _call; do
        [[ -n "${_call}" ]] || continue
        read -r -a _words <<<"${_call}"
        printf '%s\n' "${_words[@]:1}"
    done < <(grep -oE '(guard_require|_require_tools|_require_tool|_resolve_exec|type -P)( +(\\|[a-z][a-z0-9_.-]*))+' <<<"${_body}" |
        sed -E 's/^type -P/type/; s/ \\//g')
    while IFS= read -r _call; do
        [[ -n "${_call}" ]] || continue
        _var="${_call#for }"
        _var="${_var%% *}"
        [[ "${_body}" == *"_resolve_exec \"\${${_var}}\""* ]] || continue
        _call="${_call#for "${_var}" in }"
        read -r -a _words <<<"${_call%; do}"
        printf '%s\n' "${_words[@]}"
    done < <(grep -oE 'for [a-z_]+ in [a-z0-9_ .-]+; do' <<<"${_body}")
}

# The item ids body $1 runs as a child of script $2 (its basename), from
# `bash "${SCRIPT_DIR}/<script>" <args> <id>...` up to the first redirect,
# pipe or list operator.
_verify_child_items() {
    local _call _word
    local -a _words
    while IFS= read -r _call; do
        [[ -n "${_call}" ]] || continue
        read -r -a _words <<<"${_call}"
        for _word in "${_words[@]}"; do
            if [[ "${_word}" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then printf '%s\n' "${_word}"; fi
        done
    done < <(grep -oE -- "bash \"\\\$\\{SCRIPT_DIR\\}/${2//./\\.}\"[^;|&>]*" <<<"$1")
}

# The cleanup functions body $1 registers: realbox.sh's _cleanup_run
# (body $2) dispatches by token, so `_cleanup_push <token>` reaches only the
# function of that token's arm, never every arm of the dispatcher.
_verify_cleanup_arms() {
    local _token _arm
    while IFS= read -r _token; do
        [[ -n "${_token}" ]] || continue
        _arm="$(grep -oE "(^| )${_token}\) [A-Za-z_][A-Za-z0-9_]*" <<<"$2")" || {
            printf 'verify_item_tools: unknown cleanup token %s\n' "${_token}" >&2
            return 1
        }
        printf '%s\n' "${_arm##* }"
    done < <(grep -oE '_cleanup_push [A-Za-z0-9_-]+' <<<"$1" | sed 's/^_cleanup_push //')
}

verify_item_tools() {
    local _tree="$1" _s _m _mods _name _body _id _entry _entries _fn _t _cid _out="" _start_count _arms _found
    local -A _defs=() _seen=() _starts=() _counts=()
    local -a _queue=()
    shift
    (( $# > 0 )) || {
        printf 'verify_item_tools: no script given\n' >&2
        return 1
    }
    for _s in "$@"; do
        _mods="$(graph_modules "${_tree}" "${_s}")" || {
            printf 'verify_item_tools: cannot resolve the source graph of %s\n' "${_s}" >&2
            return 1
        }
        _defs=()
        while IFS=$'\t' read -r _name _body; do
            [[ -n "${_name}" ]] || continue
            _defs[${_name}]="${_body}"
        done < <(while IFS= read -r _m; do _verify_functions "${_tree}" "${_m}"; done <<<"${_mods}")
        _entries="$(_verify_item_entries "${_tree}" "${_s}")"
        # The defined entry functions of every id, for child runs.
        _starts=()
        _counts=()
        _start_count=0
        while IFS=$'\t' read -r _id _entry; do
            [[ -n "${_id}" ]] || continue
            _found=0
            for _fn in "${_entry}" "_preconditions_${_entry}"; do
                if [[ -n "${_defs[${_fn}]+x}" ]]; then
                    _starts[${_id}]+="${_fn} "
                    ((_start_count += 1))
                    _found=1
                fi
            done
            if (( _found == 0 )); then
                printf 'verify_item_tools: unresolved entry %s for item %s in %s\n' "${_entry}" "${_id}" "${_s}" >&2
                return 1
            fi
            _counts[${_id}]=0
        done <<<"${_entries}"
        while IFS=$'\t' read -r _id _entry; do
            [[ -n "${_id}" ]] || continue
            _seen=()
            _queue=()
            for _fn in "${_entry}" "_preconditions_${_entry}"; do
                if [[ -n "${_defs[${_fn}]+x}" ]]; then _queue+=("${_fn}"); fi
            done
            while (( ${#_queue[@]} > 0 )); do
                _fn="${_queue[0]}"
                _queue=("${_queue[@]:1}")
                [[ -z "${_seen[${_fn}]:-}" ]] || continue
                _seen[${_fn}]=1
                while IFS= read -r _t; do
                    if [[ -n "${_t}" ]]; then
                        _out+="${_t}"$'\t'"${_id}"$'\n'
                        _counts[${_id}]=1
                    fi
                done < <(_verify_body_tools "${_defs[${_fn}]}")
                while IFS= read -r _cid; do
                    [[ -n "${_cid}" ]] || continue
                    if [[ -z "${_starts[${_cid}]:-}" ]]; then
                        printf 'verify_item_tools: unknown child item %s in %s\n' "${_cid}" "${_s}" >&2
                        return 1
                    fi
                    for _name in ${_starts[${_cid}]}; do _queue+=("${_name}"); done
                done < <(_verify_child_items "${_defs[${_fn}]}" "${_s##*/}")
                _arms="$(_verify_cleanup_arms "${_defs[${_fn}]}" "${_defs[_cleanup_run]:-}")" || return 1
                while IFS= read -r _name; do
                    [[ -n "${_name}" ]] || continue
                    if [[ -z "${_defs[${_name}]+x}" ]]; then
                        printf 'verify_item_tools: unknown cleanup target %s in %s\n' "${_name}" "${_s}" >&2
                        return 1
                    fi
                done <<<"${_arms}"
                while IFS= read -r _name; do
                    [[ -n "${_name}" ]] || continue
                    if [[ "${_name}" != _cleanup_run && -n "${_defs[${_name}]+x}" &&
                          -z "${_seen[${_name}]:-}" ]]; then
                        _queue+=("${_name}")
                    fi
                done < <(grep -oE '[A-Za-z_][A-Za-z0-9_]*' <<<"${_defs[${_fn}]}" | sort -u
                    printf '%s\n' "${_arms}")
            done
        done <<<"${_entries}"
        for _id in "${!_counts[@]}"; do
            if [[ "${_counts[${_id}]}" == 0 ]]; then
                printf 'verify_item_tools: no tools for item %s in %s\n' "${_id}" "${_s}" >&2
                return 1
            fi
        done
        (( _start_count > 0 )) || {
            printf 'verify_item_tools: no item entry point found in %s\n' "${_s}" >&2
            return 1
        }
    done
    [[ -n "${_out}" ]] || {
        printf 'verify_item_tools: no tool derived\n' >&2
        return 1
    }
    printf '%s' "${_out}" | LC_ALL=C sort -u
}
