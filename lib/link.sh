#!/usr/bin/env bash
# lib/link.sh - link user config into the box HOME (issue #199, ADR 0002
# decision 3).
#
# The box has its own HOME (ADR 0002), so the user config the in-box git,
# gh and ssh need is not there. It is brought in with SYMLINKS ONLY: the
# host copy stays the one and only copy - nothing is copied and no host
# file is ever modified. Each entry becomes
#   <box home>/<path> -> $HOME/<path>
# an ABSOLUTE link: distrobox mounts the host HOME at the same path inside
# the box, so the link resolves there too.
#
# Entries (HOME-relative paths):
#   default  .ssh .gitconfig .gnupg .config/gh
#   extra    one `link=<path>` line each in the state file
#            ($XDG_CONFIG_HOME/worktool/config); `~/` and an absolute path
#            under $HOME are accepted, anything outside HOME or holding a
#            `..` component is warned about and skipped.
#
# Rules: an existing entry in the box HOME (file, directory or a foreign
# symlink, dangling or not) is NEVER overwritten - [WARN] and skip. A
# missing host source is skipped (no dangling link is made). Every entry is
# logged on stderr (lib/log.sh); stdout carries data only.
#
# The box HOME is the state file's `home=` value (leading `~/` expanded),
# else ~/<box>-box - the default issue #198 records there.
#
# Public API:
#   link_defaults                  -> the default entries, one per line
#   link_normalize <entry>         -> the HOME-relative path, or return 1
#   link_entries <config>          -> defaults + `link=` entries, deduped
#   link_box_home <box> <config>   -> the box HOME path
#   link_state <rel> <box_home>    -> linked | missing-source | blocked | absent
#   link_apply <box_home> <config> -> make the links; 1 when one could not be made
#
# This is a library: it defines functions and must be sourced, not executed.
# The caller sources lib/log.sh (for log_info / log_warn / log_error).

# The default user config, one HOME-relative path per line.
link_defaults() { printf '%s\n' .ssh .gitconfig .gnupg .config/gh; }

# Print entry $1 as a clean HOME-relative path: a leading `~/` or `$HOME/`
# is removed, trailing slashes are dropped. Returns 1 (printing nothing)
# for an empty path, one outside HOME, or one with a `..` component.
link_normalize() {
    local _e="$1"
    if [[ "${_e}" == \~/* ]]; then
        _e="${_e#\~/}"
    elif [[ "${_e}" == "${HOME}/"* ]]; then
        _e="${_e#"${HOME}/"}"
    fi
    while [[ "${_e}" == */ ]]; do _e="${_e%/}"; done
    [[ -n "${_e}" && "${_e}" != \~ && "${_e}" != /* ]] || return 1
    case "/${_e}/" in
        */../*|*/./*) return 1 ;;
    esac
    printf '%s\n' "${_e}"
}

# Every `<key>=` value of state file $1 for key $2, one per line, in file
# order (nothing when the file is absent).
_link_config_all() {
    [[ -f "$1" ]] || return 0
    awk -F= -v k="$2" '$1 == k { print substr($0, length(k) + 2) }' "$1"
}

# The entries to link: the defaults, then each valid `link=` line of state
# file $1, each once, in that order. An invalid line is warned about.
link_entries() {
    local _raw _rel
    local -A _seen=()
    while IFS= read -r _raw; do
        if ! _rel="$(link_normalize "${_raw}")"; then
            log_warn "link: '${_raw}' in $1 is not a path under \$HOME - skipped"
            continue
        fi
        [[ -z "${_seen[${_rel}]:-}" ]] || continue
        _seen[${_rel}]=1
        printf '%s\n' "${_rel}"
    done < <(link_defaults; _link_config_all "$1" link)
}

# The box HOME of box $1: `home=` from state file $2 (a leading `~/` is
# expanded), else ~/<box>-box.
link_box_home() {
    local _home
    _home="$(_link_config_all "$2" home)"
    _home="${_home%%$'\n'*}"
    if [[ -z "${_home}" ]]; then
        printf '%s/%s-box\n' "${HOME}" "$1"
    elif [[ "${_home}" == \~/* ]]; then
        printf '%s/%s\n' "${HOME}" "${_home#\~/}"
    else
        printf '%s\n' "${_home}"
    fi
}

# The state of entry $1 (HOME-relative) in box HOME $2:
#   linked          <box home>/<rel> is our link and the source exists
#   missing-source  the host source does not exist
#   blocked         something else already sits at <box home>/<rel>
#   absent          not linked yet, the source exists
link_state() {
    local _src="${HOME}/$1" _dst="$2/$1"
    if [[ -L "${_dst}" && "$(readlink -- "${_dst}")" == "${_src}" ]]; then
        [[ -e "${_src}" ]] && { printf 'linked\n'; return 0; }
        printf 'missing-source\n'
    elif [[ -e "${_dst}" || -L "${_dst}" ]]; then
        printf 'blocked\n'
    elif [[ ! -e "${_src}" ]]; then
        printf 'missing-source\n'
    else
        printf 'absent\n'
    fi
}

# Link one entry $1 into box HOME $2, logging what happened. Returns 1 only
# when a link that should be made could not be.
_link_one() {
    local _rel="$1" _src="${HOME}/$1" _dst="$2/$1"
    case "$(link_state "${_rel}" "$2")" in
        linked)
            log_info "link: ${_dst} -> ${_src} (already linked)" ;;
        missing-source)
            log_info "link: ${_src} not found on the host - skipped" ;;
        blocked)
            log_warn "link: ${_dst} already exists and is not a link to ${_src} - left as is (skipped)" ;;
        absent)
            if ! mkdir -p -- "$(dirname -- "${_dst}")" \
                || ! ln -s -- "${_src}" "${_dst}"; then
                log_error "link: could not link ${_dst} -> ${_src}"
                return 1
            fi
            log_info "link: ${_dst} -> ${_src}" ;;
    esac
}

# Link every entry (state file $2) into box HOME $1. Every entry is tried
# and logged; returns 1 when any link could not be made.
link_apply() {
    local _box_home="$1" _config="$2" _rel _rc=0
    while IFS= read -r _rel; do
        _link_one "${_rel}" "${_box_home}" || _rc=1
    done < <(link_entries "${_config}")
    return "${_rc}"
}
