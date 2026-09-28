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
#   terminal    ghostty|none  default ghostty when the ghostty EXECUTABLE is
#                             on PATH, or (secondary) a ghostty config dir
#                             exists; else none
#   tmux        inside|host   default inside
#   box         <name>        default dev
#   enter_keys                -> prints the four keys, one per line
#   enter_default <key>       -> prints the default of one key
#   enter_choices <key>       -> prints the allowed values (`a|b`), empty for box
#   enter_expected <key>      -> the allowed values in human form (messages)
#   enter_value_ok <key> <v>  -> 0 when <v> is an allowed value of <key>
#
# Executables the decisions depend on (issue #175):
#   enter_which <name>        -> the ABSOLUTE path PATH resolves, else 1
#   enter_terminal_detect     -> `<value> <reason>`: the terminal default and
#                                the basis of it, for the decision log
#   enter_distrobox_program   -> the distrobox a managed command must name:
#                                the absolute path, else 1 (the caller
#                                refuses the run; there is no bare-name
#                                fallback - see the function comment)
#
# Shell quoting (issue #175 round 1). BOTH managed bodies are shell SOURCE,
# not argv: ghostty runs a `command` without a `direct:` prefix through
# `/bin/sh -c`, and tmux runs `default-command` the same way. An install
# path holding a space or a shell metacharacter would otherwise be split
# into words or change what the command means.
#   enter_sh_squote <s>       -> $s as a single-quoted POSIX shell word
#   enter_sh_dquote <s>       -> $s as a double-quoted POSIX shell word
#   enter_first_word <s>      -> the first shell word of $s, decoded
#   enter_body_distrobox <b>  -> the distrobox a managed block body names
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

# --- Executables the decisions depend on (issue #175) ------------------------

# Print the ABSOLUTE path of executable $1 as the CURRENT PATH resolves it;
# return 1 when there is none. `command -v` also answers for shell
# functions, aliases and builtins, and returns a RELATIVE path when the
# PATH entry that matched was relative - none of those can be written into
# a terminal profile, so only a real, absolute, executable file is taken.
enter_which() {
    local _path
    _path="$(command -v -- "$1" 2>/dev/null)" || return 1
    [[ -n "${_path}" && "${_path}" == /* && -f "${_path}" && -x "${_path}" ]] \
        || return 1
    printf '%s\n' "${_path}"
}

# The terminal default AND the basis of it, as `<value> <reason>` (the
# value up to the first space, the reason after it), so the decision log
# can say why.
#
# The PRIMARY signal is the ghostty EXECUTABLE (issue #175): a clean
# machine has /usr/bin/ghostty and no ~/.config/ghostty yet, and judging on
# the config dir alone resolved such a machine to `none` and wrote no
# terminal profile at all - the M3 real-machine acceptance failed exactly
# there. A config dir under XDG_CONFIG_HOME or ~/.config (the two places
# ghostty itself reads) stays a SECONDARY signal, for a ghostty that is
# installed but not on this PATH.
enter_terminal_detect() {
    local _exe _dir
    if _exe="$(enter_which ghostty)"; then
        printf 'ghostty ghostty executable %s\n' "${_exe}"
        return 0
    fi
    for _dir in "$(enter_config_dir)/ghostty" "${HOME}/.config/ghostty"; do
        if [[ -d "${_dir}" ]]; then
            printf 'ghostty no ghostty executable on PATH; config dir %s\n' "${_dir}"
            return 0
        fi
    done
    printf 'none no ghostty executable on PATH and no ghostty config dir\n'
}

# The distrobox program a managed command must name: the ABSOLUTE path the
# current PATH resolves. Returns 1, printing nothing, when there is none.
#
# WHY ABSOLUTE (issue #175): a terminal started from the desktop inherits
# the systemd user manager's environment, not the user's interactive
# shell's, and that PATH routinely lacks ~/.local/bin - where distrobox's
# own installer puts it. A bare `distrobox` in the managed command died
# there with `/bin/sh: 1: distrobox: not found`.
#
# WHY THERE IS NO BARE-NAME FALLBACK (issue #175 round 1): writing the bare
# name when nothing resolves hands the user exactly the configuration the
# real machine failed on - a window that opens and closes. setup.sh knows
# at that moment that the command cannot work, so it refuses the run and
# says what to do (install distrobox, or name one with --distrobox).
#
# WHY THE SYMLINK IS KEPT: a distrobox reached through a symlink keeps the
# symlink path. That is the name the user (or their package manager)
# installed, and an upgrade replaces the target behind it, so dereferencing
# would pin a path that can disappear. Upstream's dispatcher realpath()s
# $0 before locating its distrobox-* siblings, so being invoked through the
# link is safe.
enter_distrobox_program() {
    enter_which distrobox
}

# --- Shell quoting (issue #175 round 1) --------------------------------------

# $1 as a POSIX shell word in SINGLE quotes: every character is literal, and
# an embedded single quote is closed, escaped and reopened ('\''). This is
# the only form that is safe for arbitrary text, so it is what the ghostty
# managed command uses.
enter_sh_squote() {
    local _s="$1"
    _s="${_s//\'/\'\\\'\'}"
    printf "'%s'\n" "${_s}"
}

# $1 as a POSIX shell word in DOUBLE quotes: inside "..." only \ ` $ " are
# special, so exactly those four are backslash-escaped (the backslash
# first, or the escapes would be escaped again).
#
# Used where an OUTER layer already owns the single quote: the ~/.tmux.conf
# managed block is `set -g default-command '<shell command>'`, and a tmux
# single-quoted value is fully literal - no escape, no expansion - which
# makes it the one tmux form whose content needs no second encoding. The
# price is that a path holding a single quote cannot be delivered through
# it at all; setup.sh refuses that case rather than writing a broken file.
enter_sh_dquote() {
    local _s="$1"
    _s="${_s//\\/\\\\}"
    _s="${_s//\`/\\\`}"
    _s="${_s//\$/\\\$}"
    _s="${_s//\"/\\\"}"
    printf '"%s"\n' "${_s}"
}

# The FIRST shell word of $1, decoded: a single-quoted word ('...', with
# '\'' for an embedded quote), a double-quoted word ("...", with backslash
# escapes), or - for a block an earlier worktool wrote - a bare word up to
# the first space.
enter_first_word() {
    local _s="$1" _out="" _c _esc="'\\''"
    case "${_s}" in
        "'"*)
            _s="${_s#\'}"
            while [[ -n "${_s}" ]]; do
                _c="${_s:0:1}"
                if [[ "${_c}" == "'" ]]; then
                    [[ "${_s:0:4}" == "${_esc}" ]] || break
                    _out+="'"
                    _s="${_s:4}"
                    continue
                fi
                _out+="${_c}"
                _s="${_s:1}"
            done
            ;;
        '"'*)
            _s="${_s#\"}"
            while [[ -n "${_s}" ]]; do
                _c="${_s:0:1}"
                [[ "${_c}" == '"' ]] && break
                if [[ "${_c}" == "\\" ]]; then
                    _out+="${_s:1:1}"
                    _s="${_s:2}"
                    continue
                fi
                _out+="${_c}"
                _s="${_s:1}"
            done
            ;;
        *) _out="${_s%% *}" ;;
    esac
    printf '%s\n' "${_out}"
}

# The distrobox program recorded in managed-block body $1, or nothing when
# the body names none. setup.sh writes exactly two bodies that name one:
#   command = '<distrobox>' enter <box> -- tmux new -A -s main
#   set -g default-command '"<distrobox>" enter <box>'
# (the tmux-on-host ghostty body, `command = tmux new -A -s main`, names
# none). The unquoted / double-quoted-outer shapes an earlier worktool
# wrote are still decoded, so a block a user already has keeps reporting.
# status.sh reads this back to say whether that path still runs.
enter_body_distrobox() {
    local _body="$1" _rest _prog
    case "${_body}" in
        'command = '*)               _rest="${_body#command = }" ;;
        "set -g default-command '"*) _rest="${_body#set -g default-command \'}" ;;
        'set -g default-command "'*) _rest="${_body#set -g default-command \"}" ;;
        *) return 0 ;;
    esac
    _prog="$(enter_first_word "${_rest}")"
    [[ "${_prog##*/}" == "distrobox" ]] || return 0
    printf '%s\n' "${_prog}"
}

# --- Defaults and choices ----------------------------------------------------

# The value half of enter_terminal_detect (the reason half is for the log).
_enter_default_terminal() {
    local _detected
    _detected="$(enter_terminal_detect)"
    printf '%s\n' "${_detected%% *}"
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
