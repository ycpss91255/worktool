#!/usr/bin/env bash
# lib/config.sh - the ONE reader/writer of the worktool state file
# ($XDG_CONFIG_HOME/worktool/config, issue #199 round 3).
#
# The state file has several writers: `just box setup` (the four decisions
# and their `.source`), `just box assemble` (home / home.source, issue
# #198) and the user (`link=` lines, issue #199, and anything a later
# version adds). No writer owns the whole file, so none may regenerate it:
# each one sets ITS keys in place with config_set, and every other line -
# comments, blank lines, other writers' keys, unknown keys, duplicates -
# stays byte-for-byte where it was.
#
# Format: one `key=value` per line; the key is the text before the first
# `=` (a line without `=` is a bare key with an empty value). Reads take
# the FIRST occurrence of a key.
#
# Public API:
#   config_get <file> <key>        -> the value of the first <key> line;
#                                     nothing for an absent file or key
#   config_get_all <file> <key>    -> the value of EVERY <key>= line, one
#                                     per line, in file order (keys that
#                                     may repeat, e.g. link=)
#   config_set <file> <key> <value> [<key> <value> ...]
#                                  -> set each key in place: its first line
#                                     is replaced, later lines of the same
#                                     key are dropped, a missing key is
#                                     appended (argument order); every
#                                     other line is kept. A new file starts
#                                     with a comment header. Atomic, keeps
#                                     the file's mode. 1 on failure (an odd
#                                     argument count writes nothing).
#   config_write_atomic <file>     -> replace <file> with stdin atomically
#                                     (temp file in the same directory, then
#                                     rename), keeping an existing file's
#                                     mode; used for every file worktool
#                                     rewrites
#
# This is a library: it defines functions and must be sourced, not
# executed; it sets no shell options.

config_get() {
    local _line
    [[ -f "$1" ]] || return 0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        if [[ "${_line}" == "$2" ]]; then
            return 0
        elif [[ "${_line}" == "$2="* ]]; then
            printf '%s\n' "${_line#"$2="}"
            return 0
        fi
    done <"$1"
}

config_get_all() {
    local _line
    [[ -f "$1" ]] || return 0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        [[ "${_line}" != "$2="* ]] || printf '%s\n' "${_line#"$2="}"
    done <"$1"
}

# Replace file $1 with stdin: written next to the target, then renamed, so
# a reader never sees a half-written file. An existing target keeps its
# mode (mktemp creates 0600; a user's file must not end up more private
# than they made it).
config_write_atomic() {
    local _target="$1" _tmp
    mkdir -p "$(dirname -- "${_target}")" || return 1
    _tmp="$(mktemp "${_target}.XXXXXX")" || return 1
    if cat >"${_tmp}" && _config_copy_mode "${_target}" "${_tmp}" \
        && mv -f "${_tmp}" "${_target}"; then
        return 0
    fi
    rm -f "${_tmp}"
    return 1
}

# Give file $2 the mode of file $1 when $1 exists (nothing to keep otherwise).
_config_copy_mode() {
    [[ -f "$1" ]] || return 0
    chmod --reference="$1" "$2"
}

config_set() {
    local _file="$1" _content
    shift
    if (( $# == 0 || $# % 2 != 0 )); then
        return 1
    fi
    # Rendered in full before anything is written: a read that fails half
    # way must not replace the file with half of it.
    _content="$(_config_render "${_file}" "$@")" || return 1
    printf '%s\n' "${_content}" | config_write_atomic "${_file}"
}

# Print file $1 with the key/value pairs $2.. set (see config_set). Keys
# are matched by plain string comparison, never used as array subscripts,
# so no line of the file can be mistaken for one of them.
_config_render() {
    local _file="$1" _line _key _i _n
    shift
    local -a _args=("$@") _keys=() _values=() _done=()
    for (( _i = 0; _i < ${#_args[@]}; _i += 2 )); do
        _keys+=("${_args[_i]}")
        _values+=("${_args[_i + 1]}")
        _done+=(0)
    done
    _n="${#_keys[@]}"
    if [[ -f "${_file}" ]]; then
        while IFS= read -r _line || [[ -n "${_line}" ]]; do
            _key="${_line%%=*}"
            for (( _i = 0; _i < _n; _i++ )); do
                [[ "${_key}" == "${_keys[_i]}" ]] && break
            done
            if (( _i == _n )); then
                printf '%s\n' "${_line}"
            elif (( _done[_i] == 0 )); then
                _done[_i]=1
                printf '%s=%s\n' "${_keys[_i]}" "${_values[_i]}"
            fi
        done <"${_file}" || return 1
    else
        printf '# worktool state: written by "just box setup" and "just box assemble", read by "just box status"; other lines are kept.\n'
    fi
    for (( _i = 0; _i < _n; _i++ )); do
        (( _done[_i] == 1 )) || printf '%s=%s\n' "${_keys[_i]}" "${_values[_i]}"
    done
}
