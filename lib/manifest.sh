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
# worktool ships a single shared "dev" box (doc/design.md), so a manifest is
# expected to declare exactly ONE section, and its required `image=` must live
# inside that box's own section. Whitespace-only names/values are not real
# values and are rejected - including a quoted blank ("   " or '   '):
# distrobox-assemble sources each value as a shell assignment, so single and
# double quotes are both quoting there.
#
# Public API (all read-only; none mutate the manifest):
#   manifest_name     <file>  -> prints the first [section] header's name,
#                                trimmed; returns 1 if there is no header or
#                                the name is empty/whitespace-only
#   manifest_image    <file>  -> prints the `image=` value that belongs to the
#                                box's (first) section, one paired outer pair
#                                of quotes (" or ') stripped and trimmed; a
#                                whitespace-only value prints empty
#   manifest_validate <file>  -> 0 if the manifest has a name, exactly one
#                                section, AND a non-empty image inside that
#                                section; otherwise logs a clear [ERROR] to
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

# Strip both leading and trailing whitespace.
_manifest_trim() {
    local _s
    _s="$(_manifest_ltrim "$1")"
    _manifest_rtrim "${_s}"
}

# Strip ONE outer pair of quotes from an already-trimmed value.
#
# distrobox-assemble writes each `key=value` line into a tmpfile and sources
# it as a shell assignment, so BOTH "..." and '...' are valid quoting there.
# The pair is stripped only when the first and last character are the SAME
# quote character (both " or both '); a lone quote is an empty pair (both
# ends are that one character). Anything else - a mismatched pair ('...")
# or a one-sided quote ("...) - is NOT quoting: the value is returned
# verbatim, quotes included. worktool is a pre-flight, not a shell parser;
# distrobox reports malformed quoting itself when it sources the value.
_manifest_unquote() {
    local _s="$1" _q
    [[ -n "${_s}" ]] || return 0
    _q="${_s:0:1}"
    case "${_q}" in
        \"|\')
            if [[ "${_s: -1}" == "${_q}" ]]; then
                _s="${_s#"${_q}"}"
                _s="${_s%"${_q}"}"
            fi
            ;;
    esac
    printf '%s' "${_s}"
}

# Count the number of section headers (`[...]`) in a manifest, skipping
# comment lines. Used to enforce the single-box rule.
_manifest_section_count() {
    local _file="$1" _line _n=0
    [[ -f "${_file}" ]] || { printf '0\n'; return 1; }
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _line="$(_manifest_ltrim "${_line}")"
        case "${_line}" in
            \#*|\;*) continue ;;
            \[*\]*) _n=$((_n + 1)) ;;
        esac
    done <"${_file}"
    printf '%s\n' "${_n}"
}

# --- Public: field extraction ------------------------------------------------

# manifest_name <file>: print the trimmed inner name of the first `[name]`
# section header (distrobox-assemble uses the header as the container name).
# Returns 1 if the file has no section header or the name is whitespace-only.
manifest_name() {
    local _file="$1" _line _name
    [[ -f "${_file}" ]] || return 1
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _line="$(_manifest_ltrim "${_line}")"
        case "${_line}" in
            \#*|\;*) continue ;;
            \[*\]*)
                _name="${_line#\[}"
                _name="${_name%%\]*}"
                _name="$(_manifest_trim "${_name}")"
                [[ -n "${_name}" ]] || return 1
                printf '%s\n' "${_name}"
                return 0
                ;;
        esac
    done <"${_file}"
    return 1
}

# manifest_image <file>: print the `image=` value that belongs to the box's
# own (first) section - one paired outer pair of quotes (double OR single,
# see _manifest_unquote) stripped and surrounding whitespace trimmed, so a
# quoted whitespace-only value prints empty.
# An `image=` that appears before the first section header, or inside a
# later section, does NOT belong to the box and is ignored. Returns 1 if the
# box section has no `image=` line at all (an empty value still prints an empty
# line and returns 0 - the caller decides whether empty is acceptable).
manifest_image() {
    # _state: pre  = before the first section header
    #         in   = inside the box's (first) section
    #         post = a later section has started
    local _file="$1" _line _val _state="pre"
    [[ -f "${_file}" ]] || return 1
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _line="$(_manifest_ltrim "${_line}")"
        case "${_line}" in
            \#*|\;*) continue ;;
            \[*\]*)
                if [[ "${_state}" == "pre" ]]; then
                    _state="in"
                else
                    _state="post"
                fi
                ;;
            image=*)
                [[ "${_state}" == "in" ]] || continue
                _val="${_line#image=}"
                # Trim the whole value FIRST so a leading space before an opening
                # quote (image= "   " / image= '   ') cannot leave a stray quote
                # that reads as a non-empty image; then strip ONE paired outer
                # pair of quotes (" or ', see _manifest_unquote) and trim again
                # so a quoted whitespace-only value ends up empty.
                _val="$(_manifest_trim "${_val}")"
                _val="$(_manifest_unquote "${_val}")"
                _val="$(_manifest_trim "${_val}")"
                printf '%s\n' "${_val}"
                return 0
                ;;
        esac
    done <"${_file}"
    return 1
}

# --- Public: validation ------------------------------------------------------

# manifest_validate <file>: fail fast unless the manifest exists and declares
# exactly one box section with a non-empty `image=` inside that section. Errors
# are explicit so a non-zero return is always intentional.
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

    local _name
    if ! _name="$(manifest_name "${_file}")"; then
        log_error "manifest missing box name (expected an [name] section header): ${_file}"
        return 1
    fi

    # Single-box rule: worktool ships one shared "dev" box, so more than one
    # section is ambiguous (which section's image wins?) and is rejected here.
    local _sections
    _sections="$(_manifest_section_count "${_file}")"
    if [[ "${_sections}" -gt 1 ]]; then
        log_error "manifest declares multiple sections; worktool supports a single box: ${_file}"
        return 1
    fi

    # The image must belong to the box's own section (manifest_image ignores an
    # image before/outside it), and must not be empty or whitespace-only.
    local _image
    if ! _image="$(manifest_image "${_file}")" || [[ -z "${_image}" ]]; then
        log_error "manifest missing required key 'image' in section [${_name}]: ${_file}"
        return 1
    fi

    return 0
}
