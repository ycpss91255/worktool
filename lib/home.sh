#!/usr/bin/env bash
# lib/home.sh - the box's own HOME (M3, issue #198).
#
# distrobox decides a box's HOME once, when the box is created (`--home`,
# or the DBX_CONTAINER_CUSTOM_HOME variable distrobox-create documents);
# afterwards the only way to change it is to remove the box and create it
# again. `just box assemble --home <path>` picks it (default ~/<box>-box),
# records it in the ONE state file (~/.config/worktool/config, the same
# `key=value` + `key.source=default|user` shape as `just box setup`), and
# `just box status` shows it.
#
# Public API (sourced by script/box/assemble.sh and script/box/status.sh):
#   home_default <box>            -> ${HOME}/<box>-box
#   home_normalize <path>         -> <path> without trailing slashes
#   home_path_problem <path>      -> 0 when <path> can be a box home; else
#                                    prints why not (one line) and returns 1
#   home_config_check <file>      -> 0 when the state file's home lines are
#                                    valid (the --home rules; home and
#                                    home.source together) or absent; else
#                                    prints ONE line saying why, returns 1
#   home_record <file> <path> <source>
#                                 -> rewrite the state file atomically with
#                                    exactly one home / home.source pair,
#                                    every other line kept in order
#   home_manifest_sets_home <file>-> 0 when the manifest sets distrobox's own
#                                    `home=` key (it would override --home)
#   home_of_box <box>             -> prints the HOME the EXISTING box was
#                                    created with; 1 when the container
#                                    manager lists no such box; 2 when the
#                                    box exists but its HOME cannot be
#                                    read; 3 when the manager (the one
#                                    distrobox would use, distrobox.conf
#                                    included) cannot be asked - prints why
#
# This is a library: it defines functions and must be sourced, not executed.
# It sources lib/enter.sh (same dir) for the state-file reader.

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
home_config_check() {
    [[ -f "$1" ]] || return 0
    local _line _has_home=0 _has_src=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        case "${_line}" in
            home|home=*)
                _has_home=1
                _home_check_value "${_line#home}" || return 1
                ;;
            home.source|home.source=*)
                _has_src=1
                _home_check_source "${_line#home.source}" || return 1
                ;;
        esac
    done <"$1"
    _home_check_pair "${_has_home}" "${_has_src}"
}

# $1 is what follows the key: `=<value>`, or nothing for a bare key.
_home_check_value() {
    local _v="${1#=}" _rule=0 _want
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
    local _v="${1#=}"
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

# Rewrite state file $1 with home=$2 and home.source=$3: every earlier
# home / home.source line goes, every other line stays where it was, and
# the pair is appended. Written to a temp file in the same directory and
# moved into place, so a reader never sees half a file.
home_record() {
    local _file="$1" _tmp
    mkdir -p "$(dirname -- "${_file}")" || return 1
    _tmp="$(mktemp "${_file}.XXXXXX")" || return 1
    if _home_render "$@" >"${_tmp}" && mv -f "${_tmp}" "${_file}"; then
        return 0
    fi
    rm -f "${_tmp}"
    return 1
}

_home_render() {
    if [[ -f "$1" ]]; then
        awk -F= '$1 != "home" && $1 != "home.source"' "$1" || return 1
    else
        printf '# worktool state: box home written by "just box assemble", read by "just box status".\n'
    fi
    printf 'home=%s\nhome.source=%s\n' "$2" "$3"
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
# when that manager is not on PATH.
_home_manager() {
    local _m="${DBX_CONTAINER_MANAGER:-}"
    [[ -n "${_m}" ]] || _m="$(_home_conf_manager)"
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

# The last plain `container_manager=<value>` assignment (quotes dropped)
# across distrobox's config files; nothing when none sets it.
_home_conf_manager() {
    local _f _v _m=""
    while IFS= read -r _f; do
        [[ -f "${_f}" && -r "${_f}" ]] || continue
        _v="$(sed -nE 's/^[[:space:]]*container_manager=["'\'']?([A-Za-z0-9_-]*)["'\'']?[[:space:]]*$/\1/p' "${_f}" | tail -n 1)"
        [[ -z "${_v}" ]] || _m="${_v}"
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
    local _manager _names _args
    if ! _manager="$(_home_manager)"; then
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
