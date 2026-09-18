#!/usr/bin/env bash
# lib/manifest.sh - box-manifest helpers for worktool.
#
# A worktool box manifest is a native distrobox-assemble file (INI). The
# section header is the box name; keys such as `image=` and
# `additional_packages=` are distrobox-assemble's own. worktool adopts that
# format verbatim (research-and-reuse, DRY) instead of inventing a new one,
# so `distrobox assemble create --file <manifest>` consumes it directly.
# See doc/manifest.md.
#
# Public API (all read-only; none mutate the manifest):
#   manifest_name     <file>  -> prints the first [section] header's name
#   manifest_image    <file>  -> prints the first `image=` value (unquoted)
#   manifest_validate <file>  -> 0 if the manifest has a name AND a non-empty
#                                image; otherwise logs a clear [ERROR] to
#                                stderr and returns 1
#
# This is a library: it defines functions and must be sourced, not executed.
# It sources lib/log.sh (same dir) so callers get consistent diagnostics.

# --- Dependencies ------------------------------------------------------------
# `source=` below resolves against this file's own dir (lib/).
# shellcheck source-path=SCRIPTDIR
_MANIFEST_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./log.sh
source "${_MANIFEST_LIB_DIR}/log.sh"

# --- Internal ----------------------------------------------------------------
# Strip leading whitespace from a value on stdin-free, argument form.
_manifest_ltrim() {
    local _s="$1"
    printf '%s' "${_s#"${_s%%[![:space:]]*}"}"
}

# Strip trailing whitespace.
_manifest_rtrim() {
    local _s="$1"
    printf '%s' "${_s%"${_s##*[![:space:]]}"}"
}

# --- Public: field extraction ------------------------------------------------

# manifest_name <file>: print the inner name of the first `[name]` section
# header (distrobox-assemble uses the header as the container name). Returns 1
# if the file has no section header.
manifest_name() {
    local _file="$1" _line _name
    [[ -f "${_file}" ]] || return 1
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _line="$(_manifest_ltrim "${_line}")"
        case "${_line}" in
            \[*\]*)
                _name="${_line#\[}"
                _name="${_name%%\]*}"
                [[ -n "${_name}" ]] || return 1
                printf '%s\n' "${_name}"
                return 0
                ;;
        esac
    done <"${_file}"
    return 1
}

# manifest_image <file>: print the first `image=` value, with a single pair of
# surrounding double quotes and any trailing whitespace stripped. Returns 1 if
# there is no `image=` line at all (an empty value still prints an empty line
# and returns 0 - the caller decides whether empty is acceptable).
manifest_image() {
    local _file="$1" _line _val
    [[ -f "${_file}" ]] || return 1
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _line="$(_manifest_ltrim "${_line}")"
        case "${_line}" in
            \#*|\;*) continue ;;
            image=*)
                _val="${_line#image=}"
                _val="$(_manifest_rtrim "${_val}")"
                _val="${_val#\"}"
                _val="${_val%\"}"
                printf '%s\n' "${_val}"
                return 0
                ;;
        esac
    done <"${_file}"
    return 1
}

# --- Public: validation ------------------------------------------------------

# manifest_validate <file>: fail fast unless the manifest exists and declares
# both a box name (section header) and a non-empty image. Errors are explicit
# so a non-zero return is always intentional.
manifest_validate() {
    local _file="${1:-}"

    if [[ -z "${_file}" ]]; then
        log_error "manifest_validate: no manifest path given"
        return 1
    fi
    if [[ ! -f "${_file}" ]]; then
        log_error "manifest not found: ${_file}"
        return 1
    fi
    if ! manifest_name "${_file}" >/dev/null; then
        log_error "manifest missing box name (expected an [name] section header): ${_file}"
        return 1
    fi

    local _image
    if ! _image="$(manifest_image "${_file}")" || [[ -z "${_image}" ]]; then
        log_error "manifest missing required key 'image': ${_file}"
        return 1
    fi

    return 0
}
