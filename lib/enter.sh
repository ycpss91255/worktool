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
#   enter_value_ok <key> <v>  -> 0 when <v> is an allowed value of <key>
#
# State file: `<key>=<value>` plus `<key>.source=default|user` per key.
#   enter_config_get <file> <key>   -> prints the value (nothing when absent)
#
# Managed block: at most one per file, delimited by exact marker lines, so
# it can be replaced in place and removed without touching user content.
#   enter_block_present <file>         -> 0 when the file holds the block
#   enter_block_body <file>            -> prints the lines between the markers
#   enter_block_strip <file>           -> file content minus the block, stdout
#   enter_block_compose <file> <body>  -> stripped content + block, stdout
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

# 0 when $2 is a valid value for key $1. The box name follows the container
# name rule (docker / podman): [A-Za-z0-9][A-Za-z0-9_.-]*.
enter_value_ok() {
    local _key="$1" _value="$2" _choices
    if [[ "${_key}" == "box" ]]; then
        [[ "${_value}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
    else
        _choices="$(enter_choices "${_key}")" || return 1
        [[ -n "${_value}" && "|${_choices}|" == *"|${_value}|"* ]]
    fi
}

# --- State file --------------------------------------------------------------

# Print the value of key $2 in state file $1 (first match; nothing when the
# file or the key is absent). Exact key match on the text before the first
# `=`, so `box` never matches `box.source`.
enter_config_get() {
    [[ -f "$1" ]] || return 0
    awk -F= -v k="$2" '$1 == k { print substr($0, length(k) + 2); exit }' "$1"
}

# --- Managed block -----------------------------------------------------------

enter_block_present() {
    [[ -f "$1" ]] && grep -qxF "${ENTER_BLOCK_BEGIN}" "$1"
}

# Print the lines between the markers of the block in file $1.
enter_block_body() {
    [[ -f "$1" ]] || return 0
    awk -v b="${ENTER_BLOCK_BEGIN}" -v e="${ENTER_BLOCK_END}" \
        '$0 == e { inside = 0 } inside { print } $0 == b { inside = 1 }' "$1"
}

# Print file $1 without its managed block (markers included). A missing
# file prints nothing.
enter_block_strip() {
    [[ -f "$1" ]] || return 0
    awk -v b="${ENTER_BLOCK_BEGIN}" -v e="${ENTER_BLOCK_END}" \
        '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$1"
}

# Print file $1 with its managed block replaced IN PLACE (same position,
# body $2) or, when the file has none, appended at the end - so the result
# holds exactly one block and user lines keep their order. The body travels
# through the environment, not `-v`, so awk never interprets escapes in it.
enter_block_compose() {
    if [[ ! -f "$1" ]]; then
        printf '%s\n%s\n%s\n' "${ENTER_BLOCK_BEGIN}" "$2" "${ENTER_BLOCK_END}"
        return 0
    fi
    ENTER_BODY="$2" awk -v b="${ENTER_BLOCK_BEGIN}" -v e="${ENTER_BLOCK_END}" '
        $0 == b { print; print ENVIRON["ENTER_BODY"]; skip = 1; done = 1; next }
        skip && $0 == e { print; skip = 0; next }
        !skip { print }
        END {
            if (skip) { print e }
            if (!done) { print b; print ENVIRON["ENTER_BODY"]; print e }
        }
    ' "$1"
}
