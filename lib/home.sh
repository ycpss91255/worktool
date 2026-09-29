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
#                                    valid (or absent); else prints ONE
#                                    `invalid value ...` line, returns 1
#   home_record <file> <path> <source>
#                                 -> rewrite the state file atomically with
#                                    exactly one home / home.source pair,
#                                    every other line kept in order
#   home_manifest_sets_home <file>-> 0 when the manifest sets distrobox's own
#                                    `home=` key (it would override --home)
#   home_of_box <box>             -> prints the HOME the EXISTING box was
#                                    created with; 1 when there is no such
#                                    box (or no container manager to ask);
#                                    2 when the box exists but its HOME
#                                    cannot be read
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

# Why path $1 cannot be a box home, or nothing (return 0) when it can. The
# state file is line-based, and distrobox bind-mounts the path under the
# same name, so it must be absolute, single-line and not the root itself.
home_path_problem() {
    if [[ "$1" != /* ]]; then
        printf "needs an absolute path, got '%s'\n" "$1"
    elif [[ "$1" == *$'\n'* || "$1" == *$'\r'* ]]; then
        printf 'cannot hold a newline or carriage return\n'
    elif [[ "$(home_normalize "$1")" == / ]]; then
        printf 'cannot be the root directory\n'
    else
        return 0
    fi
    return 1
}

# Validate the home lines of state file $1 (every occurrence, like
# enter_config_check does for the auto-enter keys).
home_config_check() {
    [[ -f "$1" ]] || return 0
    awk -F= '
        $1 == "home" {
            v = substr($0, 6)
            if (v !~ /^\//) { printf "invalid value '\''%s'\'' for home (expected an absolute path)\n", v; exit 1 }
        }
        $1 == "home.source" {
            v = substr($0, 13)
            if (v != "default" && v != "user") { printf "invalid value '\''%s'\'' for home.source (expected default|user)\n", v; exit 1 }
        }
    ' "$1"
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

# The container manager distrobox would use: DBX_CONTAINER_MANAGER when it
# names one, else the autodetect order of distrobox-create 1.8.2.5
# (podman, podman-launcher, docker). Returns 1 when none is on PATH.
# A manager chosen in distrobox.conf is not read (documented limit).
_home_manager() {
    local _m="${DBX_CONTAINER_MANAGER:-autodetect}"
    if [[ "${_m}" != autodetect ]]; then
        command -v -- "${_m}" >/dev/null 2>&1 || return 1
        printf '%s\n' "${_m}"
        return 0
    fi
    for _m in podman podman-launcher docker; do
        if command -v -- "${_m}" >/dev/null 2>&1; then
            printf '%s\n' "${_m}"
            return 0
        fi
    done
    return 1
}

# The HOME existing box $1 was created with: distrobox hands its init
# `--home <path>` (the custom home, or the host HOME when there was none),
# and the manager keeps those entrypoint arguments. Returns 1 when the
# manager says there is no such container, or there is no manager to ask
# (then distrobox itself will say what is wrong); 2 when the box exists
# but carries no `--home` argument (not a box distrobox created).
home_of_box() {
    local _manager _args
    _manager="$(_home_manager)" || return 1
    _args="$("${_manager}" inspect --type container \
        --format '{{range .Args}}{{println .}}{{end}}' "$1" 2>/dev/null)" \
        || return 1
    awk 'f { print; done = 1; exit } $0 == "--home" { f = 1 }
         END { if (!done) exit 2 }' <<<"${_args}"
}
