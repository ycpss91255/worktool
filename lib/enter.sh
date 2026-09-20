#!/usr/bin/env bash
# lib/enter.sh - shared helpers for the auto-enter setup (M3, issue #21).
#
# Sourced by script/box/setup.sh (decides and writes) and
# script/box/status.sh (reads and reports), so both agree on paths, the
# defaults, the state-file format and the managed-block markers.
#
# Every path derives from HOME / XDG_CONFIG_HOME ONLY (tests point HOME at
# a throwaway directory; the real home is never touched by a spec):
#   enter_config_dir       -> ${XDG_CONFIG_HOME:-$HOME/.config}
#   enter_config_path      -> <config dir>/worktool/config   (the ONE state file)
#   enter_ghostty_config   -> <config dir>/ghostty/config
#   enter_tmux_conf        -> $HOME/.tmux.conf
#
# Decisions (the keys of the state file) and their defaults:
#   auto-enter  yes|no        default yes
#   terminal    ghostty|none  default ghostty when <config dir>/ghostty or
#                             ~/.config/ghostty exists, else none
#   tmux        inside|host   default inside
#   box         <name>        default dev
#   enter_keys                -> prints the four keys, one per line
#   enter_default <key>       -> prints the default of one key
#   enter_choices <key>       -> prints the allowed values (`a|b`), empty for box
#   enter_expected <key>      -> the allowed values in human form (messages)
#   enter_value_ok <key> <v>  -> 0 when <v> is an allowed value of <key>
#
# State file: `<key>=<value>` plus `<key>.source=default|user` per key.
#   enter_key_known <key>           -> 0 when <key> is a decision key or a
#                                      `<key>.source`
#   enter_config_get <file> <key>   -> prints the value (nothing when absent;
#                                      first occurrence when repeated)
#   enter_config_check <file>       -> 0 when EVERY LINE holding a known key
#                                      (repeats and empty values included)
#                                      has a valid value or source (whatever
#                                      the source says: the file is
#                                      user-editable); else prints ONE
#                                      `invalid value ...` line and returns 1
#
# Managed block: exactly one per file, delimited by exact marker lines, so
# it can be replaced in place and removed without touching user content. A
# file that somehow holds several blocks is collapsed to one on rewrite.
#   enter_block_present <file>         -> 0 when the file holds a block
#   enter_block_count <file>           -> number of blocks (0 when absent)
#   enter_block_body <file>            -> lines between the FIRST block's markers
#   enter_block_strip <file>           -> file content minus EVERY block, stdout
#   enter_block_compose <file> <body>  -> content with exactly one block, stdout
#
# This is a library: it defines functions and must be sourced, not executed.
# Sourcing has no side effects.

ENTER_BLOCK_BEGIN='# BEGIN worktool managed block (just box setup; do not edit)'
ENTER_BLOCK_END='# END worktool managed block'

# The decision keys, one per line, in report order.
enter_keys() { printf '%s\n' auto-enter terminal tmux box; }

# --- Paths -------------------------------------------------------------------
enter_config_dir() { printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}"; }
enter_config_path() { printf '%s/worktool/config\n' "$(enter_config_dir)"; }
enter_ghostty_config() { printf '%s/ghostty/config\n' "$(enter_config_dir)"; }
enter_tmux_conf() { printf '%s/.tmux.conf\n' "${HOME}"; }

# --- Defaults and choices ----------------------------------------------------

# ghostty is the detected default when it has a config dir under either
# XDG_CONFIG_HOME or ~/.config (the two places ghostty itself reads).
_enter_default_terminal() {
    if [[ -d "$(enter_config_dir)/ghostty" || -d "${HOME}/.config/ghostty" ]]; then
        printf 'ghostty\n'
    else
        printf 'none\n'
    fi
}

enter_default() {
    case "$1" in
        auto-enter) printf 'yes\n' ;;
        terminal)   _enter_default_terminal ;;
        tmux)       printf 'inside\n' ;;
        box)        printf 'dev\n' ;;
        *)          return 1 ;;
    esac
}

# Allowed values of key $1 as `a|b`; empty for the free-form box name.
enter_choices() {
    case "$1" in
        auto-enter) printf 'yes|no\n' ;;
        terminal)   printf 'ghostty|none\n' ;;
        tmux)       printf 'inside|host\n' ;;
        box)        printf '\n' ;;
        *)          return 1 ;;
    esac
}

# The allowed values of key $1 in human form, for error messages: the
# choices, or the container name rule for the free-form box name. A
# `<key>.source` key allows the two sources.
enter_expected() {
    case "$1" in
        box)        printf 'a container name: [A-Za-z0-9][A-Za-z0-9_.-]*\n' ;;
        *.source)   printf 'default|user\n' ;;
        *)          enter_choices "$1" ;;
    esac
}

# 0 when $2 is a valid value for key $1. The box name follows the container
# name rule (docker / podman): [A-Za-z0-9][A-Za-z0-9_.-]*; a `<key>.source`
# key takes default|user.
enter_value_ok() {
    local _key="$1" _value="$2" _choices
    case "${_key}" in
        box)      [[ "${_value}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ;;
        *.source) [[ "${_value}" == "default" || "${_value}" == "user" ]] ;;
        *)
            _choices="$(enter_choices "${_key}")" || return 1
            [[ -n "${_value}" && "|${_choices}|" == *"|${_value}|"* ]]
            ;;
    esac
}

# --- State file --------------------------------------------------------------

# Print the value of key $2 in state file $1 (first match; nothing when the
# file or the key is absent). Exact key match on the text before the first
# `=`, so `box` never matches `box.source`.
enter_config_get() {
    [[ -f "$1" ]] || return 0
    awk -F= -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }' "$1"
}

# 0 when $1 is a key the state file may hold: a decision key or its
# `<key>.source` companion.
enter_key_known() {
    enter_keys | grep -qxF -- "${1%.source}"
}

# Validate state file $1 LINE BY LINE: every line whose key is known must
# hold an allowed value, WHATEVER the source says (the file is user-editable,
# so a default-sourced line can be corrupt too). An absent file or key is
# fine (defaults apply) - but a PRESENT key with an empty value is a stored
# value and is refused like any other. Every line is checked, so a corrupt
# duplicate behind a valid first occurrence is refused too (reads take the
# first occurrence; the check must not). On the first bad line, in file
# order, prints `invalid value '<v>' for <key> (expected <...>)` on stdout
# and returns 1, so the caller can prefix the path and refuse the run
# before writing.
enter_config_check() {
    local _file="$1" _line _key _value
    [[ -f "${_file}" ]] || return 0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        [[ "${_line}" == *=* ]] || continue
        _key="${_line%%=*}"
        enter_key_known "${_key}" || continue
        _value="${_line#*=}"
        enter_value_ok "${_key}" "${_value}" && continue
        printf "invalid value '%s' for %s (expected %s)\n" \
            "${_value}" "${_key}" "$(enter_expected "${_key}")"
        return 1
    done <"${_file}"
}

# --- Managed block -----------------------------------------------------------

enter_block_present() {
    [[ -f "$1" ]] && grep -qxF "${ENTER_BLOCK_BEGIN}" "$1"
}

# Number of begin markers in file $1 (0 when the file is absent).
enter_block_count() {
    [[ -f "$1" ]] || { printf '0\n'; return 0; }
    grep -cxF "${ENTER_BLOCK_BEGIN}" "$1" || true
}

# Print the lines between the markers of the FIRST block in file $1.
enter_block_body() {
    [[ -f "$1" ]] || return 0
    awk -v b="${ENTER_BLOCK_BEGIN}" -v e="${ENTER_BLOCK_END}" \
        '$0 == e && inside { exit } inside { print } $0 == b { inside = 1 }' "$1"
}

# Print file $1 without ANY managed block (markers included). A missing
# file prints nothing.
enter_block_strip() {
    [[ -f "$1" ]] || return 0
    awk -v b="${ENTER_BLOCK_BEGIN}" -v e="${ENTER_BLOCK_END}" \
        '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$1"
}

# Print file $1 holding EXACTLY ONE managed block with body $2: every
# existing block is stripped, then the one block is put where the first
# used to be (in place, so user lines keep their order) or, when the file
# had none, appended at the end. The body travels through the environment,
# not `-v`, so awk never interprets escapes in it.
enter_block_compose() {
    if [[ ! -f "$1" ]]; then
        printf '%s\n%s\n%s\n' "${ENTER_BLOCK_BEGIN}" "$2" "${ENTER_BLOCK_END}"
        return 0
    fi
    ENTER_BODY="$2" awk -v b="${ENTER_BLOCK_BEGIN}" -v e="${ENTER_BLOCK_END}" '
        function block() { print b; print ENVIRON["ENTER_BODY"]; print e }
        $0 == b { if (!done) { block(); done = 1 }; skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
        END { if (!done) block() }
    ' "$1"
}
