#!/usr/bin/env bash
# lib/config.sh - the ONE reader/writer of the worktool state file
# ($XDG_CONFIG_HOME/worktool/config, issue #199 rounds 3-4).
#
# The state file has several writers: `just box setup` (the four decisions
# and their `.source`), `just box assemble` (home / home.source, issue
# #198) and the user (`link=` lines, issue #199, and anything a later
# version adds). No writer owns the whole file, so none may regenerate it:
# each one sets ITS keys in place with config_set, and every other byte -
# comments, blank and whitespace-only lines, other writers' keys, unknown
# keys, duplicates, CRLF line endings, trailing blank lines, a missing
# final newline - stays where it was. Readers (the validators included)
# go through config_get / config_get_all / config_each; nothing outside
# this file opens the state file.
#
# Format: one `key=value` per line; the key is the text before the first
# `=` (a line without `=` is a bare key with an empty value). Reads take
# the FIRST occurrence of a key. A line's bytes are never re-encoded: a
# CRLF line keeps its `\r` (as part of its value, which the validators of
# the known keys then refuse).
#
# Public API:
#   config_get <file> <key>        -> the value of the first <key> line;
#                                     nothing for an absent file or key
#   config_get_all <file> <key>    -> the value of EVERY <key>= line, one
#                                     per line, in file order (keys that
#                                     may repeat, e.g. link=)
#   config_each <file> <fn> [args...]
#                                  -> call `<fn> [args...] <lineno> <key>
#                                     <has_value 0|1> <value>` for every
#                                     line that is not a comment or blank,
#                                     in file order; stop at and return the
#                                     first non-zero status
#   config_set <file> <key> <value> [<key> <value> ...]
#                                  -> set each key in place: its first line
#                                     is replaced, later lines of the same
#                                     key are dropped, a missing key is
#                                     appended (argument order; a newline
#                                     is added first only when the file's
#                                     last line has none); every other byte
#                                     is kept. A new file starts with a
#                                     comment header. Rendered straight
#                                     into a temp file and renamed (atomic),
#                                     keeps the file's mode, serialised by
#                                     a lock (flock on the file's
#                                     directory; a `<file>.lock` directory
#                                     where flock is missing). 1 on failure
#                                     (an odd argument count writes nothing).
#   config_write_atomic <file>     -> replace <file> with stdin atomically
#                                     (temp file in the same directory, then
#                                     rename), keeping an existing file's
#                                     mode; used for every file worktool
#                                     rewrites
#
# No file content ever passes through a command substitution here: `$(...)`
# drops trailing newlines, which would change the bytes this file keeps.
#
# This is a library: it defines functions and must be sourced, not
# executed; it sets no shell options.

# --- Reading -----------------------------------------------------------------

# Call `$2.. <lineno> <line>` for every line of file $1, the last one too
# when it has no newline; stop at and return the first non-zero status.
_config_lines() {
    local _file="$1" _line _n=0 _rc
    shift
    [[ -f "${_file}" ]] || return 0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _n=$(( _n + 1 ))
        _rc=0
        "$@" "${_n}" "${_line}" || _rc=$?
        [[ "${_rc}" -eq 0 ]] || return "${_rc}"
    done <"${_file}"
}

config_each() {
    local _file="$1"
    shift
    _config_lines "${_file}" _config_each_line "$@"
}

# $1.. the callback and its args, then <lineno> <line> (the last two).
_config_each_line() {
    local _line="${*: -1}" _n="${*: -2:1}"
    local -a _cb=("${@:1:$#-2}")
    [[ "${_line}" =~ ^[[:space:]]*(#|$) ]] && return 0
    if [[ "${_line}" == *=* ]]; then
        "${_cb[@]}" "${_n}" "${_line%%=*}" 1 "${_line#*=}"
    else
        "${_cb[@]}" "${_n}" "${_line}" 0 ""
    fi
}

config_get() {
    local _rc=0
    _config_lines "$1" _config_get_line "$2" || _rc=$?
    # 10 is "found and printed": stop reading.
    [[ "${_rc}" -eq 0 || "${_rc}" -eq 10 ]]
}

_config_get_line() {
    if [[ "$3" == "$1" ]]; then
        return 10
    elif [[ "$3" == "$1="* ]]; then
        printf '%s\n' "${3#"$1="}"
        return 10
    fi
}

config_get_all() {
    _config_lines "$1" _config_get_all_line "$2"
}

_config_get_all_line() {
    [[ "$3" != "$1="* ]] || printf '%s\n' "${3#"$1="}"
}

# --- Writing -----------------------------------------------------------------

# Replace file $1 with the output of command $2..: the output goes straight
# into a temp file next to the target, which is then renamed over it, so a
# reader never sees a half-written file. An existing target keeps its mode
# (mktemp creates 0600; a user's file must not end up more private than
# they made it).
_config_replace() {
    local _target="$1" _tmp
    shift
    mkdir -p -- "$(dirname -- "${_target}")" || return 1
    _tmp="$(mktemp "${_target}.XXXXXX")" || return 1
    if "$@" >"${_tmp}" && _config_copy_mode "${_target}" "${_tmp}" \
        && mv -f -- "${_tmp}" "${_target}"; then
        return 0
    fi
    rm -f -- "${_tmp}"
    return 1
}

config_write_atomic() {
    _config_replace "$1" cat
}

# Give file $2 the mode of file $1 when $1 exists (nothing to keep otherwise).
_config_copy_mode() {
    [[ -f "$1" ]] || return 0
    chmod --reference="$1" "$2"
}

config_set() {
    local _file="$1"
    shift
    if (( $# == 0 || $# % 2 != 0 )); then
        return 1
    fi
    mkdir -p -- "$(dirname -- "${_file}")" || return 1
    _config_locked "${_file}" _config_replace "${_file}" _config_render "${_file}" "$@"
}

# 0 when flock(1) is available (a seam: the tests take the other path).
_config_have_flock() {
    command -v flock >/dev/null 2>&1
}

# Run $2.. holding the lock of state file $1, so two writers never
# interleave their read-modify-rename (the second one's rename would erase
# the first one's keys). flock on the file's directory (the file itself is
# replaced by the rename, so it cannot carry the lock); without flock, an
# atomic mkdir of `<file>.lock`, retried for up to 10 s.
_config_locked() {
    local _file="$1" _rc=0 _fd _i
    shift
    if _config_have_flock; then
        exec {_fd}<"$(dirname -- "${_file}")" || return 1
        if ! flock -x "${_fd}"; then
            exec {_fd}<&-
            return 1
        fi
        "$@" || _rc=$?
        exec {_fd}<&-
        return "${_rc}"
    fi
    for (( _i = 0; _i < 200; _i++ )); do
        mkdir -- "${_file}.lock" 2>/dev/null && break
        sleep 0.05
    done
    (( _i < 200 )) || return 1
    "$@" || _rc=$?
    rmdir -- "${_file}.lock"
    return "${_rc}"
}

# Print file $1 with the key/value pairs $2.. set (see config_set), byte
# for byte: each line is re-emitted with exactly the terminator it had
# (none for a last line without a newline). Keys are matched by plain
# string comparison, never used as array subscripts, so no line of the
# file can be mistaken for one of them.
_config_render() {
    local _file="$1" _line _key _i _n _eol _last_eol=$'\n'
    shift
    local -a _args=("$@") _keys=() _values=() _done=()
    for (( _i = 0; _i < ${#_args[@]}; _i += 2 )); do
        _keys+=("${_args[_i]}")
        _values+=("${_args[_i + 1]}")
        _done+=(0)
    done
    _n="${#_keys[@]}"
    if [[ -f "${_file}" ]]; then
        while :; do
            _eol=$'\n'
            if ! IFS= read -r _line; then
                [[ -n "${_line}" ]] || break
                _eol=''
            fi
            _key="${_line%%=*}"
            for (( _i = 0; _i < _n; _i++ )); do
                [[ "${_key}" == "${_keys[_i]}" ]] && break
            done
            if (( _i == _n )); then
                printf '%s%s' "${_line}" "${_eol}"
                _last_eol="${_eol}"
            elif (( _done[_i] == 0 )); then
                _done[_i]=1
                printf '%s=%s%s' "${_keys[_i]}" "${_values[_i]}" "${_eol}"
                _last_eol="${_eol}"
            fi
            [[ -n "${_eol}" ]] || break
        done <"${_file}" || return 1
    else
        printf '# worktool state: written by "just box setup" and "just box assemble", read by "just box status"; other lines are kept.\n'
    fi
    for (( _i = 0; _i < _n; _i++ )); do
        (( _done[_i] == 1 )) && continue
        # Separate the key from a last line that has no newline.
        [[ -n "${_last_eol}" ]] || printf '\n'
        printf '%s=%s\n' "${_keys[_i]}" "${_values[_i]}"
        _last_eol=$'\n'
    done
}
