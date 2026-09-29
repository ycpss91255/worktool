#!/usr/bin/env bash
# lib/home.sh - the box's own HOME (M3, issue #198).
#
# distrobox decides a box's HOME once, when the box is created (`--home`,
# or the DBX_CONTAINER_CUSTOM_HOME variable distrobox-create documents);
# afterwards the only way to change it is to remove the box and create it
# again. `just box assemble --home <path>` picks it (default ~/<box>-box),
# records it in the ONE state file (lib/config.sh, the same
# `key=value` + `key.source=default|user` shape as `just box setup`), and
# `just box status` shows it.
#
# Public API (sourced by script/box/assemble.sh and script/box/status.sh):
#   home_default <box>            -> ${HOME}/<box>-box
#   home_normalize <path>         -> <path> without trailing slashes
#   home_path_problem <path>      -> 0 when <path> can be a box home; else
#                                    prints why not (one line) and returns 1
#   home_config_check             -> 0 when the state file's home lines are
#                                    valid (the --home rules; home and
#                                    home.source together) or absent; else
#                                    prints ONE line saying why, returns 1
#   home_record <path> <source>
#                                 -> set home / home.source in the state
#                                    file in place (lib/config.sh), every
#                                    other line kept byte-for-byte
#   home_manifest_sets_home <file>-> 0 when the manifest sets distrobox's own
#                                    `home=` key (it would override --home)
#   home_of_box <box>             -> prints the HOME the EXISTING box was
#                                    created with; 1 when the container
#                                    manager lists no such box; 2 when the
#                                    box exists but its HOME cannot be
#                                    read; 3 when the manager (the one
#                                    distrobox would use, distrobox.conf
#                                    included) cannot be asked, or a
#                                    container_manager= line cannot be
#                                    read - prints why
#
# This is a library: it defines functions and must be sourced, not executed.
# It sources lib/enter.sh (same dir), which brings lib/config.sh, the state
# file's one reader/writer.

# shellcheck source-path=SCRIPTDIR
_HOME_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./enter.sh
source "${_HOME_LIB_DIR}/enter.sh"

home_default() { printf '%s/%s-box\n' "${HOME}" "$1"; }

# Strip trailing slashes (distrobox-create does the same to --home), but
# never turn a path into the empty string.
home_normalize() {
    local _p="$1"
    while [[ "${_p}" == */ && "${_p}" != / ]]; do
        _p="${_p%/}"
    done
    printf '%s\n' "${_p}"
}

# Which rule path $1 breaks as a box home: 0 none, 1 not absolute, 2 holds
# a newline or carriage return, 3 the root itself. The state file is
# line-based, and distrobox bind-mounts the path under the same name. The
# ONE rule set behind both the --home check and the state-file check.
_home_path_rule() {
    if [[ "$1" != /* ]]; then
        return 1
    elif [[ "$1" == *$'\n'* || "$1" == *$'\r'* ]]; then
        return 2
    elif [[ "$(home_normalize "$1")" == / ]]; then
        return 3
    fi
    return 0
}

# Why path $1 cannot be a box home, or nothing (return 0) when it can.
home_path_problem() {
    local _rule=0
    _home_path_rule "$1" || _rule=$?
    case "${_rule}" in
        0) return 0 ;;
        1) printf "needs an absolute path, got '%s'\n" "$1" ;;
        2) printf 'cannot hold a newline or carriage return\n' ;;
        3) printf 'cannot be the root directory\n' ;;
    esac
    return 1
}

# Validate the home lines of state file $1: every occurrence of `home`
# meets the --home rules, every `home.source` is default|user, and the
# two are present together (a lone home.source would resolve to an empty
# box home). Prints ONE line saying why and returns 1 on the first fault.
# The file is read through lib/config.sh (config_each), never directly.
home_config_check() {
    local _has_home=0 _has_src=0
    config_each _home_check_entry || return 1
    _home_check_pair "${_has_home}" "${_has_src}"
}

# One entry of the state file (config_each: <lineno> <key> <has_value>
# <value>); sets home_config_check's _has_home / _has_src.
_home_check_entry() {
    case "$2" in
        home)
            _has_home=1
            _home_check_value "$4"
            ;;
        home.source)
            _has_src=1
            _home_check_source "$4"
            ;;
    esac
}

# $1 is the value (empty for a bare key).
_home_check_value() {
    local _v="$1" _rule=0 _want
    _home_path_rule "${_v}" || _rule=$?
    case "${_rule}" in
        0) return 0 ;;
        1) _want='an absolute path' ;;
        2) _want='no carriage return' ;;
        3) _want='a path other than the root directory' ;;
    esac
    printf "invalid value '%s' for home (expected %s)\n" \
        "$(enter_show_control "${_v}")" "${_want}"
    return 1
}

_home_check_source() {
    local _v="$1"
    [[ "${_v}" == default || "${_v}" == user ]] && return 0
    printf "invalid value '%s' for home.source (expected default|user)\n" \
        "$(enter_show_control "${_v}")"
    return 1
}

_home_check_pair() {
    if [[ "$1" -eq 1 && "$2" -eq 0 ]]; then
        printf 'home without home.source (the two are recorded together)\n'
    elif [[ "$1" -eq 0 && "$2" -eq 1 ]]; then
        printf 'home.source without home (the two are recorded together)\n'
    else
        return 0
    fi
    return 1
}

# Record home=$2 and home.source=$3 in state file $1 IN PLACE (lib/config.sh
# config_set): the two lines are replaced where they are (a duplicate is
# dropped), or appended; every line another writer owns stays as it was.
# Atomic, keeps the file's mode.
home_record() {
    config_set home "$1" home.source "$2"
}

# 0 when manifest $1 sets distrobox-assemble's own `home=` key (leading
# whitespace allowed, comments skipped): distrobox would pass it as --home
# and it would win over the path worktool resolved.
home_manifest_sets_home() {
    grep -qE '^[[:space:]]*home[[:space:]]*=' "$1"
}

# The container manager distrobox would use, the way distrobox-create
# 1.8.2.5 picks it: DBX_CONTAINER_MANAGER when set and non-empty, else the
# last `container_manager=` of its config files (read, never sourced),
# else autodetect in its order (podman, podman-launcher, docker, lilipod).
# Prints the name; returns 1 (still printing the name, or `autodetect`)
# when that manager is not on PATH; 2 (printing the config file) when a
# `container_manager=` line there cannot be read as a manager name.
_home_manager() {
    local _m="${DBX_CONTAINER_MANAGER:-}"
    if [[ -z "${_m}" ]] && ! _m="$(_home_conf_manager)"; then
        printf '%s\n' "${_m}"
        return 2
    fi
    [[ -n "${_m}" ]] || _m=autodetect
    if [[ "${_m}" == autodetect ]]; then
        local _c
        for _c in podman podman-launcher docker lilipod; do
            if command -v -- "${_c}" >/dev/null 2>&1; then
                printf '%s\n' "${_c}"
                return 0
            fi
        done
        printf '%s\n' "${_m}"
        return 1
    fi
    printf '%s\n' "${_m}"
    command -v -- "${_m}" >/dev/null 2>&1
}

# The config files distrobox-create reads, lowest priority first.
_home_conf_files() {
    local _dbx
    if _dbx="$(command -v distrobox 2>/dev/null)" && [[ "${_dbx}" == /* ]]; then
        printf '%s\n' "$(dirname -- "$(realpath -- "${_dbx}")")/../share/distrobox/distrobox.conf"
    fi
    printf '%s\n' /usr/share/distrobox/distrobox.conf \
        /usr/share/defaults/distrobox/distrobox.conf \
        /usr/etc/distrobox/distrobox.conf \
        /usr/local/share/distrobox/distrobox.conf \
        /etc/distrobox/distrobox.conf \
        "${XDG_CONFIG_HOME:-${HOME}/.config}/distrobox/distrobox.conf" \
        "${HOME}/.distroboxrc"
}

# The last `container_manager=<value>` assignment across distrobox's
# config files, read the way the shell reads a plain name: optional
# matching quotes, optional trailing `# comment`. Nothing when none sets
# it. A line it cannot read that way (empty, a substitution, ...) returns
# 1 printing that file: distrobox sources it, so skipping it could ask a
# different manager than the one distrobox uses.
_home_conf_manager() {
    local _f _line _m=""
    local _q="'" _re
    # No back-reference: POSIX ERE (musl) has none, so spell the 3 quotings.
    _re='^[[:space:]]*container_manager=([A-Za-z0-9_-]+|"[A-Za-z0-9_-]+"|'
    _re+="${_q}[A-Za-z0-9_-]+${_q}"')([[:space:]]+#.*)?[[:space:]]*$'
    while IFS= read -r _f; do
        [[ -f "${_f}" && -r "${_f}" ]] || continue
        while IFS= read -r _line || [[ -n "${_line}" ]]; do
            [[ "${_line}" =~ ^[[:space:]]*container_manager= ]] || continue
            if [[ ! "${_line}" =~ ${_re} ]]; then
                printf '%s\n' "${_f}"
                return 1
            fi
            _m="${BASH_REMATCH[1]//[\"\']/}"
        done <"${_f}"
    done < <(_home_conf_files)
    printf '%s\n' "${_m}"
}

# The HOME existing box $1 was created with: distrobox hands its init
# `--home <path>` (the custom home, or the host HOME when there was none),
# and the manager keeps those entrypoint arguments. Existence comes from
# the manager's container listing, so a failing manager is never mistaken
# for a missing box. Returns 0 (prints the HOME), 1 when the manager lists
# no such container, 2 when the box exists but its HOME cannot be read
# (inspect failed, or no `--home` argument: not a box distrobox created),
# 3 when the manager cannot be asked (prints why, one line).
home_of_box() {
    local _manager _names _args _rc=0
    _manager="$(_home_manager)" || _rc=$?
    if [[ "${_rc}" -eq 2 ]]; then
        printf 'cannot read container_manager in %s\n' "${_manager}"
        return 3
    elif [[ "${_rc}" -ne 0 ]]; then
        printf "container manager '%s' not found on PATH\n" "${_manager}"
        return 3
    fi
    if ! _names="$("${_manager}" ps -a --format '{{.Names}}' 2>/dev/null)"; then
        printf "'%s ps' failed\n" "${_manager}"
        return 3
    fi
    grep -qxF -- "$1" <<<"${_names}" || return 1
    _args="$("${_manager}" inspect --type container \
        --format '{{range .Args}}{{println .}}{{end}}' "$1" 2>/dev/null)" \
        || return 2
    awk 'f { print; done = 1; exit } $0 == "--home" { f = 1 }
         END { if (!done) exit 2 }' <<<"${_args}"
}
