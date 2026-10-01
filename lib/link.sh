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
#            (lib/config.sh); `~/` and an absolute path
#            under $HOME are accepted, anything outside HOME or holding a
#            `..` component is warned about and skipped.
#
# Rules: an existing entry in the box HOME (file, directory or a foreign
# symlink, dangling or not) is NEVER overwritten - [WARN] and skip. Nothing
# is ever written outside the box HOME: the box HOME itself, or a parent
# directory of an entry in it, that is a symlink (or not a directory) is
# never followed - [WARN] and skip. A
# missing host source is skipped (no dangling link is made). Every entry is
# logged on stderr (lib/log.sh); stdout carries data only.
#
# The box HOME is the caller's: script/box/assemble.sh passes the one it
# resolved and recorded (lib/home.sh, issue #198), script/box/status.sh the
# recorded one. A box whose HOME is the host HOME already sees the user
# config, so there is nothing to link.
#
# Public API:
#   link_defaults                  -> the default entries, one per line
#   link_normalize <entry>         -> the HOME-relative path, or return 1
#   link_entries                   -> defaults + `link=` entries, deduped
#   link_state <rel> <box_home>    -> linked | missing-source | blocked | absent
#   link_apply <box_home>          -> make the links; 1 when one could not be made
#
# This is a library: it defines functions and must be sourced, not executed.
# The caller sources lib/log.sh (for log_info / log_warn / log_error); this
# file sources lib/config.sh (same dir) to read the state file's link= lines.

# shellcheck source-path=SCRIPTDIR
_LINK_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./config.sh
source "${_LINK_LIB_DIR}/config.sh"

# The default user config, one HOME-relative path per line.
link_defaults() { printf '%s\n' .ssh .gitconfig .gnupg .config/gh; }

# Print entry $1 as a clean HOME-relative path: a leading `~/` or `$HOME/`
# is removed, trailing slashes are dropped. Returns 1 (printing nothing)
# for an empty or blank path, one outside HOME, or one with a `..` component.
link_normalize() {
    local _e="$1"
    if [[ "${_e}" == \~/* ]]; then
        _e="${_e#\~/}"
    elif [[ "${_e}" == "${HOME}/"* ]]; then
        _e="${_e#"${HOME}/"}"
    fi
    while [[ "${_e}" == */ ]]; do _e="${_e%/}"; done
    [[ "${_e}" =~ [^[:space:]] && "${_e}" != \~ && "${_e}" != /* ]] || return 1
    case "/${_e}/" in
        */../*|*/./*) return 1 ;;
    esac
    printf '%s\n' "${_e}"
}

# The entries to link: the defaults, then each valid `link=` line of the
# state file, each once, in that order. An invalid line is warned about.
link_entries() {
    local _raw _rel
    local -A _seen=()
    while IFS= read -r _raw; do
        if ! _rel="$(link_normalize "${_raw}")"; then
            config_log warn "link: '${_raw}' in " " is not a path under \$HOME - skipped"
            continue
        fi
        [[ -z "${_seen[${_rel}]:-}" ]] || continue
        _seen[${_rel}]=1
        printf '%s\n' "${_rel}"
    done < <(link_defaults; config_get_all link)
}

# Return 0, printing it, when box HOME $2 itself or a parent directory of
# entry $1 (HOME-relative) inside it is a symlink or exists as something
# other than a directory: following it could create the link outside the
# box HOME (mkdir -p and ln -s both follow a symlinked directory).
_link_parent_unsafe() {
    local _dir="$2" _part
    local -a _parts
    # A trailing slash would make -L test the symlink's target instead.
    while [[ "${_dir}" == ?*/ ]]; do _dir="${_dir%/}"; done
    IFS=/ read -r -a _parts <<<"$1"
    for _part in "" "${_parts[@]:0:${#_parts[@]}-1}"; do
        _dir="${_dir}${_part:+/${_part}}"
        if [[ -L "${_dir}" || (-e "${_dir}" && ! -d "${_dir}") ]]; then
            printf '%s\n' "${_dir}"
            return 0
        fi
    done
    return 1
}

# The state of entry $1 (HOME-relative) in box HOME $2:
#   linked          <box home>/<rel> is our link and the source exists
#   missing-source  the host source does not exist
#   blocked         something else already sits at <box home>/<rel>, or the
#                   box HOME or a parent of <rel> in it is a symlink or not
#                   a directory
#   absent          not linked yet, the source exists
link_state() {
    local _src="${HOME}/$1" _dst="$2/$1"
    if _link_parent_unsafe "$1" "$2" >/dev/null; then
        printf 'blocked\n'
    elif [[ -L "${_dst}" && "$(readlink -- "${_dst}")" == "${_src}" ]]; then
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
    local _rel="$1" _src="${HOME}/$1" _dst="$2/$1" _parent
    case "$(link_state "${_rel}" "$2")" in
        linked)
            log_info "link: ${_dst} -> ${_src} (already linked)" ;;
        missing-source)
            log_info "link: ${_src} not found on the host - skipped" ;;
        blocked)
            if _parent="$(_link_parent_unsafe "${_rel}" "$2")"; then
                log_warn "link: ${_parent} (parent of ${_dst}) is a symlink or not a directory - not followed (skipped)"
            else
                log_warn "link: ${_dst} already exists and is not a link to ${_src} - left as is (skipped)"
            fi ;;
        absent)
            if ! mkdir -p -- "$(dirname -- "${_dst}")" \
                || ! ln -s -- "${_src}" "${_dst}"; then
                log_error "link: could not link ${_dst} -> ${_src}"
                return 1
            fi
            log_info "link: ${_dst} -> ${_src}" ;;
    esac
}

# Link every entry into box HOME $1. Every entry is tried and logged;
# returns 1 when any link could not be made. The entry list is read in full
# first, so its warnings (an invalid `link=`) come before the link log lines
# in one fixed order: a process substitution would run link_entries
# alongside the loop and interleave the two on stderr.
link_apply() {
    local _box_home="$1" _rel _rc=0 _entries
    _entries="$(link_entries)"
    while IFS= read -r _rel; do
        [[ -n "${_rel}" ]] || continue
        _link_one "${_rel}" "${_box_home}" || _rc=1
    done <<<"${_entries}"
    return "${_rc}"
}
