#!/usr/bin/env bash
# lib/enter.sh - shared helpers for the auto-enter setup (M3, issue #21).
#
# Sourced by script/box/setup.sh (decides and writes) and
# script/box/status.sh (reads and reports), so both agree on paths, the
# defaults, the state-file format and the managed-block markers.
#
# Every path derives from HOME / XDG_CONFIG_HOME ONLY (tests point HOME at
# a throwaway directory; the real home is never touched by a spec):
#   enter_config_dir       -> ${XDG_CONFIG_HOME:-$HOME/.config} (lib/config.sh)
#   (the ONE state file is lib/config.sh's; nothing here names it)
#   enter_ghostty_target   -> existing config.ghostty, otherwise legacy config
#   enter_distrobox_conf   -> <config dir>/distrobox/distrobox.conf
#
# There is no tmux decision and no ~/.tmux.conf path (issue #179): the
# terminal enters the box and gets its login shell; tmux is something the
# user starts inside the box, where it gets the box's own server
# (TMUX_TMPDIR, box/dev.ini). worktool never reads or writes the host's
# tmux config.
#
# The box's tmux environment (issue #179, codex round 4 on PR #232):
#   enter_distrobox_conf_body <box> -> the ONE line setup.sh keeps in the
#                             managed block of distrobox's own user config,
#                             so no `distrobox enter <box>` ever hands the
#                             box the caller's TMUX / TMUX_PANE (see the
#                             function comment).
#
# Decisions (the keys of the state file) and their defaults:
#   auto-enter  yes|no        default yes
#   terminal    ghostty|none  default ghostty when the ghostty EXECUTABLE is
#                             on PATH, or (secondary) a ghostty config dir
#                             exists; else none
#   box         <name>        default dev
#   enter_keys                -> prints the three keys, one per line
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
# Shell quoting (issue #175 round 1). The managed body is shell SOURCE, not
# argv: ghostty runs a `command` without a `direct:` prefix through
# `/bin/sh -c`. An install path holding a space or a shell metacharacter
# would otherwise be split into words or change what the command means.
#   enter_sh_squote <s>       -> $s as a single-quoted POSIX shell word
#   enter_first_word <s>      -> the first shell word of $s, decoded
#   enter_after_first_word <s>-> $s minus its first (setup-encoded) word
#   enter_body_distrobox <b>  -> the distrobox a managed block body names
#                                (through the enter.sh wrapper, issues #180, #360)
#   enter_path_single_line <p>-> 0 when $p holds no newline / carriage return
#   enter_show_control <s>    -> $s with LF / CR shown as `\n` / `\r`
#
# State file (lib/config.sh owns it; read with config_get <key>):
# `<key>=<value>` plus `<key>.source=default|user` per key.
#   enter_key_known <key>           -> 0 when <key> is a decision key or a
#                                      `<key>.source` (a `tmux` line an
#                                      earlier worktool stored is not: it
#                                      is ignored, and preserved on rewrite)
#   enter_config_check       -> 0 when EVERY LINE holding a known key
#                                      (repeats and empty values included)
#                                      has a valid value or source (whatever
#                                      the source says: the file is
#                                      user-editable); else prints ONE
#                                      `invalid value ...` line and returns 1
#
# Managed block: exactly one per file, delimited by exact marker lines, so
# it can be replaced in place and removed without touching user content.
# The helpers below TRUST the markers, so a writer validates them first:
#   enter_block_check <file>           -> 0 when well-formed (no marker, or
#                                         one exact BEGIN ... END); else
#                                         prints the problems with their
#                                         line numbers and returns 1
#   enter_block_present <file>         -> 0 when the file holds a block
#   enter_block_count <file>           -> number of blocks (0 when absent)
#   enter_block_body <file>            -> lines between the FIRST block's markers
#   enter_block_strip <file>           -> file content minus EVERY block, stdout
#   enter_block_compose <file> <body>  -> content with exactly one block, stdout
#
# This is a library: it defines functions and must be sourced, not executed.
# Sourcing has no side effects; it sources lib/config.sh (same dir), the
# one reader/writer of the state file.

# The state file's format is lib/config.sh's (its one reader/writer).
# shellcheck source-path=SCRIPTDIR
_ENTER_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./config.sh
source "${_ENTER_LIB_DIR}/config.sh"

ENTER_BLOCK_BEGIN='# BEGIN worktool managed block (just box setup; do not edit)'
ENTER_BLOCK_END='# END worktool managed block'

# The decision keys, one per line, in report order.
enter_keys() { printf '%s\n' auto-enter terminal box; }

# --- Paths -------------------------------------------------------------------
enter_config_dir() { config_xdg_dir; }
enter_ghostty_target() {
    local _legacy
    _legacy="$(enter_config_dir)/ghostty/config"
    if [[ -e "${_legacy}.ghostty" ]]; then
        printf '%s\n' "${_legacy}.ghostty"
    else
        printf '%s\n' "${_legacy}"
    fi
}
# distrobox reads this file itself, on every run, from the same
# ${XDG_CONFIG_HOME:-$HOME/.config} (pinned distrobox 1.8.2.5, the
# config_files list of distrobox-enter).
enter_distrobox_conf() { printf '%s/distrobox/distrobox.conf\n' "$(enter_config_dir)"; }

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

# Encode a legacy double-quoted wrapper path for status readback.
enter_sh_dquote() {
    local _s="$1"
    _s="${_s//\\/\\\\}"
    _s="${_s//\`/\\\`}"
    _s="${_s//\$/\\\$}"
    _s="${_s//\"/\\\"}"
    printf '"%s"\n' "${_s}"
}

# 0 when $1 can be written into a managed block at all (issue #175 round
# 2): no newline and no carriage return.
#
# Shell quoting makes a valid WORD out of any text, but the managed file is
# LINE-BASED - ghostty reads its config line by line. A path holding a
# newline therefore splits the managed body across two
# lines, and ghostty rejects the whole file with `unknown field` - after
# setup had already written it and exited 0. There is no encoding that
# fixes this, so such a path is refused instead.
enter_path_single_line() {
    [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

# $1 with every newline / carriage return shown as `\n` / `\r`, so a path
# holding one can still be named in a ONE-LINE diagnostic.
enter_show_control() {
    local _s="$1"
    _s="${_s//$'\r'/\\r}"
    _s="${_s//$'\n'/\\n}"
    printf '%s\n' "${_s}"
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

# $1 with its FIRST shell word removed (and the one space after it), or
# nothing (return 1) when that word is not encoded the way setup.sh encodes
# one: the decoded word is re-encoded in the same quoting style and must be
# exactly the prefix of $1.
enter_after_first_word() {
    local _s="$1" _word _enc
    _word="$(enter_first_word "${_s}")"
    case "${_s}" in
        "'"*) _enc="$(enter_sh_squote "${_word}")" ;;
        '"'*) _enc="$(enter_sh_dquote "${_word}")" ;;
        *)    _enc="${_word}" ;;
    esac
    [[ "${_s}" == "${_enc} "* ]] || return 1
    printf '%s\n' "${_s#"${_enc} "}"
}

# The distrobox program recorded in ghostty managed-block body $1, or
# nothing when the body names none. setup.sh writes one body:
#   command = '<repo>/script/box/enter.sh' --distrobox '<distrobox>' --box '<box>'
# Legacy direct-distrobox bodies are also decoded.
# The shapes an earlier worktool wrote (`... -- tmux new -A -s main`
# after it, an unquoted path) are still decoded, so a block a user already
# has keeps reporting. status.sh reads this back to say whether that path
# still runs.
enter_body_distrobox() {
    local _body="$1" _rest _prog
    case "${_body}" in
        'command = '*) _rest="${_body#command = }" ;;
        *) return 0 ;;
    esac
    _prog="$(enter_first_word "${_rest}")"
    if [[ "${_prog##*/}" == "enter.sh" ]]; then
        _rest="$(enter_after_first_word "${_rest}")" || return 0
        [[ "${_rest}" == "--distrobox "* ]] || return 0
        _prog="$(enter_first_word "${_rest#--distrobox }")"
    fi
    [[ "${_prog##*/}" == "distrobox" ]] || return 0
    printf '%s\n' "${_prog}"
}

# The wrapper target recorded in a managed body, without executing shell code.
enter_body_wrapper() {
    local _body="$1" _prog
    [[ "${_body}" == 'command = '* ]] || return 0
    _prog="$(enter_first_word "${_body#command = }")"
    [[ "${_prog##*/}" == enter.sh ]] || return 0
    printf '%s\n' "${_prog}"
}

# --- The box's tmux environment (issue #179) ---------------------------------

# The managed body of distrobox.conf for box $1: ONE line of POSIX sh that
# drops TMUX and TMUX_PANE when the distrobox run it is sourced into
# targets box $1.
#
# WHY THE ENVIRONMENT, NOT THE BINARY (codex rounds 1-4 on PR #232): the
# leak is not a tmux binary. `distrobox enter` copies the caller's whole
# environment into the box (distrobox-enter's generate_enter_command turns
# `printenv` into one `--env` per variable; only a fixed list - HOME, PATH,
# PWD, ... - is skipped, and TMUX is not on it). Entered from a HOST tmux
# pane, the box therefore inherits TMUX, which names the host server's
# socket on the /tmp distrobox shares with the host, and tmux prefers the
# socket in $TMUX over TMUX_TMPDIR. Any wrapper around the tmux binary is
# bypassed by running the real binary (`distrobox enter dev -- <real
# tmux>`, where no box shell ever runs). The only place every entry passes
# through is distrobox-enter itself, before it builds the `exec` request.
#
# WHY distrobox.conf: distrobox-enter SOURCES its config files as shell,
# before it reads its own arguments and before that `printenv`; there is
# no skip-list option and no `--unset` flag (an `--additional-flags "--env
# TMUX="` would still pass an empty TMUX, and a managed terminal command
# prefixed with `env -u TMUX` covers that one command only). An `unset`
# there is simply never copied.
#
# ONLY THE BOX WORKTOOL MANAGES: the line applies to box $1 - the box
# `just box setup` is configured for (`box`, default dev) - and to no other
# box, which keeps the upstream behaviour. Sourced, the file sees
# distrobox-enter's own arguments as "$@", and it decides the target the
# way distrobox-enter's own option loop does (pinned 1.8.2.5), never by
# "some token equals the box name" (codex round 4 on PR #232: an option
# VALUE equal to the name must not count):
#   - -n / --name and -a / --additional-flags take a value; only the
#     -n / --name value is a box name;
#   - every other option is a flag; every positional argument sets the
#     name, so the LAST one wins;
#   - `--`, `-e`, `--exec` end the options (what follows is the command);
#   - no name on the command line: DBX_CONTAINER_NAME.
# It never shifts or sets distrobox-enter's "$@" and unsets its own
# variables.
#
# $1 is a validated box name (enter_value_ok), written single-quoted.
enter_distrobox_conf_body() {
    local _box _line
    _box="$(enter_sh_squote "$1")"
    _line="$(cat <<'EOF'
_worktool_n=; _worktool_v=; for _worktool_a in "$@"; do if [ -n "${_worktool_v}" ]; then [ "${_worktool_v}" = n ] && [ -n "${_worktool_a}" ] && _worktool_n="${_worktool_a}"; _worktool_v=; continue; fi; case "${_worktool_a}" in --|-e|--exec) break ;; -n|--name) _worktool_v=n ;; -a|--additional-flags) _worktool_v=a ;; -*) ;; *) _worktool_n="${_worktool_a}" ;; esac; done; [ "${_worktool_n:-${DBX_CONTAINER_NAME:-}}" != @BOX@ ] || unset TMUX TMUX_PANE; unset _worktool_a _worktool_n _worktool_v
EOF
)"
    printf '%s\n' "${_line//@BOX@/${_box}}"
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
        box)        printf 'dev\n' ;;
        *)          return 1 ;;
    esac
}

# Allowed values of key $1 as `a|b`; empty for the free-form box name.
enter_choices() {
    case "$1" in
        auto-enter) printf 'yes|no\n' ;;
        terminal)   printf 'ghostty|none\n' ;;
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
# before writing. The file is read through lib/config.sh (config_each).
enter_config_check() {
    config_each _enter_check_entry
}

# One entry of the state file (config_each: <lineno> <key> <has_value>
# <value>): every line of a known key is judged; a bare `<key>` line is that
# key with an empty value (lib/config.sh's format) and is judged as such.
_enter_check_entry() {
    local _key="$2" _value="$4"
    enter_key_known "${_key}" || return 0
    enter_value_ok "${_key}" "${_value}" && return 0
    printf "invalid value '%s' for %s (expected %s)\n" \
        "${_value}" "${_key}" "$(enter_expected "${_key}")"
    return 1
}

# --- Managed block -----------------------------------------------------------

# Validate the marker structure of file $1 (issue #179, codex round 4 on PR
# #232): 0 when the file is absent, holds no marker, or holds exactly one
# well-formed block; otherwise prints the problems, with their line
# numbers, as ONE `; `-joined line and returns 1. Every writer checks this
# FIRST: the helpers below trust the markers, and an orphan BEGIN used to
# make compose / strip drop every line after it. Malformed is:
#   an unpaired BEGIN or END, END before BEGIN, a BEGIN inside a block,
#   more than one block, and a marker line with any extra text (leading
#   blanks, trailing text or blanks).
enter_block_check() {
    [[ -f "$1" ]] || return 0
    awk -v b="${ENTER_BLOCK_BEGIN}" -v e="${ENTER_BLOCK_END}" '
        function p(s) { msg = msg (msg == "" ? "" : "; ") s }
        BEGIN { pb = "# BEGIN worktool managed block"; pe = "# END worktool managed block" }
        { l = $0; sub(/^[ \t]+/, "", l) }
        $0 == b {
            if (open) p("nested BEGIN at line " NR " (BEGIN at line " ob " has no END yet)")
            else { open = 1; ob = NR }
            nb++; bl = bl (bl == "" ? "" : ", ") NR
            next
        }
        $0 == e {
            if (!open) p("END at line " NR " has no BEGIN")
            else open = 0
            next
        }
        index(l, pb) == 1 || index(l, pe) == 1 { p("line " NR " is a marker with extra text") }
        END {
            if (open) p("BEGIN at line " ob " has no END")
            if (nb > 1) p(nb " blocks (BEGIN at lines " bl "), at most one is allowed")
            if (msg != "") { print msg; exit 1 }
        }
    ' "$1"
}

enter_block_present() {
    [[ -f "$1" ]] && grep -qxF "${ENTER_BLOCK_BEGIN}" "$1"
}

# Number of begin markers in file $1 (0 when the file is absent). `grep -c`
# prints 0 AND exits 1 when nothing matches: that 1 is expected and
# handled; only a real grep error (2) is returned.
enter_block_count() {
    [[ -f "$1" ]] || { printf '0\n'; return 0; }
    local _rc=0
    grep -cxF "${ENTER_BLOCK_BEGIN}" "$1" || _rc=$?
    (( _rc <= 1 )) || return "${_rc}"
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
