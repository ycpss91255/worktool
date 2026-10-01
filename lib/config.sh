#!/usr/bin/env bash
# lib/config.sh - the ONE owner of the worktool state file (issue #199).
#
# The state file has several writers: `just box setup` (the four decisions
# and their `.source`), `just box assemble` (home / home.source, issue
# #198) and the user (`link=` lines, issue #199, and anything a later
# version adds). No writer owns the whole file, so none may regenerate it:
# each one sets ITS keys in place with config_set.
#
# Format: one `key=value` per line; the key is the text before the first
# `=` (a line without `=` is a bare key with an empty value).
#
# API (what each call promises is the contract below, nothing else):
#   config_xdg_dir                     ${XDG_CONFIG_HOME:-$HOME/.config}
#   config_exists
#   config_get <key>
#   config_get_all <key>
#   config_each <fn> [args...]         calls <fn> [args...] <lineno> <key>
#                                      <has_value 0|1> <value>
#   config_set <key> <value> [<key> <value> ...]
#   config_log <info|warn|error> <before> [<after>]   (caller sources lib/log.sh)
#   config_say <before> [<after>]
#   config_fill                        stdin -> stdout
#   config_write_atomic <file>         stdin -> <file> (the terminal
#                                      profiles; not the state file)
#
# Contract. Each `@prop` line is one promise with a stable ID. What is
# checked (test/unit/config_mutation_spec.bats), and nothing more:
#   - exactly one table row per @prop line, every ID once in each (a drift
#     guard fails otherwise);
#   - each row's mutant makes the spec cases the row names fail;
#   - renderer rows (what config_set writes) also change only their own
#     element of the written bytes; behavioural rows are only "caught";
#   - `owner` is checked over every entry point the argument parsers expose
#     and every module in a source graph reaching lib/config.sh from script/
#     that names a public config_* function or XDG_CONFIG_HOME in a
#     non-comment line (test/unit/config_owner_spec.bats); modules that
#     name neither are not checked.
#   @prop location      the state file resolves to
#                       $XDG_CONFIG_HOME/worktool/config, else
#                       ~/.config/worktool/config
#   @prop owner         no other module reads or writes the state file by
#                       building its path
#   @prop exists        config_exists succeeds only when the state file exists
#   @prop get-first     config_get prints the value of the FIRST line of the key
#   @prop get-bare      a bare `<key>` line counts as that key with an empty value
#   @prop get-lf        config_get prints the value and one LF when the key is
#                       present (a bare key: just LF, like `<key>=`), nothing
#                       when it is absent
#   @prop get-all       config_get_all prints every value of the key, in file order
#   @prop get-all-bare  config_get_all prints a bare `<key>` line as an empty value
#   @prop bare-validate the validators (lib/enter.sh, lib/home.sh) judge a bare
#                       `<key>` line exactly like `<key>=`
#   @prop each-args     config_each passes line number, key, has_value, value
#   @prop each-skip     config_each skips comment and blank lines
#   @prop each-stop     config_each stops at, and returns, the first non-zero status
#   @prop log           config_log names the state file in its message
#   @prop say           config_say names the state file on stdout
#   @prop fill          config_fill replaces every `{state-file}` with
#                       $XDG_CONFIG_HOME/worktool/config
#   @prop in-place      config_set replaces a key's first line where it stands
#   @prop dup-owned     config_set drops the later lines of a key it sets
#   @prop append-order  config_set appends missing keys in argument order
#   @prop append-sep    config_set adds a newline before appended keys only
#                       when the last line has none
#   @prop new-header    a new state file starts with one comment header line
#   @prop comments      config_set keeps comment lines
#   @prop blank         config_set keeps blank and whitespace-only lines,
#                       anywhere (trailing ones too)
#   @prop crlf          config_set keeps the CR of every line but the last
#   @prop eof           config_set keeps the final line's terminator (LF,
#                       CRLF or none)
#   @prop foreign-known config_set keeps other writers' keys
#   @prop unknown       config_set keeps keys worktool does not know
#   @prop dup-foreign   config_set keeps duplicated lines it does not own
#   @prop order         config_set keeps the order of the lines it does not own
#   @prop odd-args      config_set refuses an odd argument count, writing nothing
#   @prop fail-nothing  config_set writes nothing when rendering fails
#   @prop atomic        config_set replaces the file by rename (a reader
#                       holding the old file keeps the old bytes)
#   @prop mode          config_set keeps the file's mode
#   @prop lock          config_set calls are serialised by flock(1)
#   @prop no-flock      without flock(1) config_set refuses (error, exit 1)
#                       and writes nothing
#   @prop wa-atomic     config_write_atomic replaces its file by rename
#   @prop wa-mode       config_write_atomic keeps its file's mode
#
# No file content passes through a command substitution here: `$(...)`
# drops trailing newlines.
#
# This is a library: it defines functions and must be sourced, not
# executed; it sets no shell options.

# --- Location (the only place that knows it) ---------------------------------

config_xdg_dir() { printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}"; }

# WORKTOOL_CONFIG_FILE is a TEST-ONLY seam, honoured here and nowhere else:
# test/unit/config_owner_spec.bats points it at a random path and poisons
# the default location, so a module that computed the path itself would
# read or write the poison and fail there. Users never set it.
_config_file() {
    if [[ -n "${WORKTOOL_CONFIG_FILE:-}" ]]; then
        printf '%s\n' "${WORKTOOL_CONFIG_FILE}"
    else
        printf '%s/worktool/config\n' "$(config_xdg_dir)"
    fi
}

config_exists() { [[ -f "$(_config_file)" ]]; }

config_log() {
    local _level="$1"
    "log_${_level}" "$2$(_config_file)${3:-}"
}

config_say() { printf '%s%s%s\n' "$1" "$(_config_file)" "${2:-}"; }

config_fill() {
    local _line _where="\$XDG_CONFIG_HOME/worktool/config"
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        printf '%s\n' "${_line//\{state-file\}/${_where}}"
    done
}

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
    _config_lines "$(_config_file)" _config_each_line "$@"
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
    _config_lines "$(_config_file)" _config_get_line "$1" || _rc=$?
    # 10 is "found and printed": stop reading.
    [[ "${_rc}" -eq 0 || "${_rc}" -eq 10 ]]
}

_config_get_line() {
    if [[ "$3" == "$1" ]]; then
        printf '\n'
        return 10
    elif [[ "$3" == "$1="* ]]; then
        printf '%s\n' "${3#"$1="}"
        return 10
    fi
}

config_get_all() {
    _config_lines "$(_config_file)" _config_get_all_line "$1"
}

_config_get_all_line() {
    if [[ "$3" == "$1" ]]; then
        printf '\n'
    elif [[ "$3" == "$1="* ]]; then
        printf '%s\n' "${3#"$1="}"
    fi
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
    local _file
    if (( $# == 0 || $# % 2 != 0 )); then
        return 1
    fi
    _file="$(_config_file)"
    if ! _config_have_flock; then
        log_error "flock (util-linux) not found: cannot lock ${_file} for writing"
        return 1
    fi
    mkdir -p -- "$(dirname -- "${_file}")" || return 1
    _config_locked "${_file}" _config_replace "${_file}" _config_render "${_file}" "$@"
}

# 0 when flock(1) is available (a seam: a test takes the refusal path).
_config_have_flock() {
    command -v flock >/dev/null 2>&1
}

# Run $2.. holding the lock of state file $1, so two writers never
# interleave their read-modify-rename (the second one's rename would erase
# the first one's keys): flock on the file's directory (the file itself is
# replaced by the rename, so it cannot carry the lock). flock(1) is part of
# util-linux, on every platform worktool supports; without it the write is
# refused (fails closed) rather than done unserialised - a hand-made lock
# needs stale-lock breaking, and breaking a lock atomically is exactly
# what flock already does (the kernel drops it when its holder dies).
_config_locked() {
    local _file="$1" _rc=0 _fd
    shift
    exec {_fd}<"$(dirname -- "${_file}")" || return 1
    if ! flock -x "${_fd}"; then
        exec {_fd}<&-
        return 1
    fi
    "$@" || _rc=$?
    exec {_fd}<&-
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
