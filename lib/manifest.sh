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
# double quotes are both quoting there. For the same reason an UNBALANCED
# outer quote (a lone ' or ", a mismatched '..." pair, a one-sided "... or
# ...") is a shell syntax error upstream, so it is rejected here, early, with
# a distinct message (see _manifest_unquote for the exact rule).
#
# Public API (all read-only; none mutate the manifest):
#   manifest_name     <file>  -> prints the first [section] header's name,
#                                trimmed; returns 1 if there is no header or
#                                the name is empty/whitespace-only
#   manifest_image    <file>  -> prints the `image=` value that belongs to the
#                                box's (first) section, one matched outer pair
#                                of quotes (" or ') stripped and trimmed; a
#                                whitespace-only value prints empty. Returns 1
#                                if the section has no `image=` line; returns
#                                2 (printing the trimmed raw value) when the
#                                value has an unbalanced outer quote
#   manifest_validate <file>  -> 0 if the manifest has a name, exactly one
#                                section, AND a non-empty, well-quoted image
#                                inside that section; otherwise logs a clear
#                                [ERROR] to stderr and returns 1
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
# it as a shell assignment, so BOTH "..." and '...' are valid quoting there -
# and an unterminated or mismatched outer quote is a shell SYNTAX ERROR
# upstream. Rule: if the first OR last character is a quote (" or '), the
# value must be a MATCHED pair - the same quote character at both ends and
# length >= 2 - and exactly that one pair is stripped (printed, return 0).
# Any other leading/trailing quote - a lone ' or " (length 1), a mismatched
# pair ('..."), a one-sided quote ("... or ...") - is malformed: nothing is
# printed and 2 is returned so the caller can reject it with a clear message
# instead of letting distrobox emit a shell error later. Quotes strictly
# inside the value are left alone.
_manifest_unquote() {
    local _s="$1"
    [[ -n "${_s}" ]] || return 0
    case "${_s:0:1}${_s: -1}" in
        \"\"|\'\')
            # Same quote at both ends. A lone quote is "both ends" at once
            # (length 1), which is not a pair.
            [[ ${#_s} -ge 2 ]] || return 2
            _s="${_s#?}"
            printf '%s' "${_s%?}"
            ;;
        \"*|\'*|*\"|*\') return 2 ;;
        *) printf '%s' "${_s}" ;;
    esac
    return 0
}

# Normalise a raw `image=` value: trim the whole value FIRST so a leading
# space before an opening quote (image= "   " / image= '   ') cannot leave a
# stray quote that reads as a non-empty image; then strip ONE matched outer
# pair of quotes (see _manifest_unquote) and trim again so a quoted
# whitespace-only value ends up empty. Prints the normalised value (no
# newline) and returns 0. On an unbalanced outer quote it prints the trimmed
# RAW value instead and returns 2, so the caller can name the offending
# value in its diagnostic.
_manifest_image_value() {
    local _raw _val
    _raw="$(_manifest_trim "$1")"
    if ! _val="$(_manifest_unquote "${_raw}")"; then
        printf '%s' "${_raw}"
        return 2
    fi
    _manifest_trim "${_val}"
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
# own (first) section - one matched outer pair of quotes (double OR single,
# see _manifest_unquote) stripped and surrounding whitespace trimmed, so a
# quoted whitespace-only value prints empty.
# An `image=` that appears before the first section header, or inside a
# later section, does NOT belong to the box and is ignored. Returns 1 if the
# box section has no `image=` line at all (an empty value still prints an empty
# line and returns 0 - the caller decides whether empty is acceptable).
# Returns 2 - printing the trimmed raw value - when the value has an
# unbalanced outer quote (see _manifest_image_value).
manifest_image() {
    # _state: pre  = before the first section header
    #         in   = inside the box's (first) section
    #         post = a later section has started
    local _file="$1" _line _val _state="pre" _rc=0
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
                _val="$(_manifest_image_value "${_line#image=}")" || _rc=$?
                printf '%s\n' "${_val}"
                return "${_rc}"
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
    # image before/outside it), must not be empty or whitespace-only, and must
    # not carry an unbalanced outer quote (rc 2: a shell syntax error once
    # distrobox sources it - reject here, before distrobox is ever called).
    local _image _rc=0
    _image="$(manifest_image "${_file}")" || _rc=$?
    if [[ "${_rc}" -eq 2 ]]; then
        log_error "manifest image value has an unbalanced quote: ${_image} (section [${_name}]): ${_file}"
        return 1
    fi
    if [[ "${_rc}" -ne 0 || -z "${_image}" ]]; then
        log_error "manifest missing required key 'image' in section [${_name}]: ${_file}"
        return 1
    fi

    return 0
}
