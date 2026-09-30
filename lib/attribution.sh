#!/usr/bin/env bash
# lib/attribution.sh - the attribution-line detector (issue #270).
#
# Maintainer rule: commit messages, PR / issue bodies and comments carry no
# attribution line. ONE pattern table below defines what counts; the
# agent-side hook (.agents/hook/enforce_no_attribution.sh) and the CI check
# of commit messages / PR bodies (issue #271) both call attribution_find,
# so the two can never disagree.
#
# A line is an attribution line when, lower-cased and with its leading and
# trailing whitespace removed, it matches one ERE of the table. Prose that
# merely mentions claude, a co-author or generated files does not match.
#
# Public API:
#   attribution_patterns
#       -> prints the table, one ERE per line (for a caller that must show
#          or reuse the rule without restating it).
#   attribution_find <text>
#       -> prints every attribution line of <text>, trimmed, one per line
#          (data, on stdout); exit 0 when there is at least one, 1 when
#          there is none.
#
# This is a library: it defines functions and must be sourced, not
# executed. It sets no shell options and prints nothing at source time.

# The table: matched against the lower-cased, trimmed line.
_attribution_table() {
    printf '%s\n' \
        '^co-authored-by:[[:space:]]*claude([^[:alnum:]]|$)' \
        '^co-authored-by:.*@anthropic\.com' \
        '^claude-session:' \
        'generated with \[?claude code([^[:alnum:]]|$)'
}

attribution_patterns() {
    _attribution_table
}

# _attribution_trim <line> - the line without leading / trailing space.
_attribution_trim() {
    local _l="$1"
    _l="${_l#"${_l%%[![:space:]]*}"}"
    printf '%s' "${_l%"${_l##*[![:space:]]}"}"
}

# _attribution_is_line <trimmed line> - 0 when it matches the table.
_attribution_is_line() {
    local _low="${1,,}" _re
    while IFS= read -r _re; do
        [[ "${_low}" =~ ${_re} ]] && return 0
    done < <(_attribution_table)
    return 1
}

attribution_find() {
    local _line _t _found=1
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _t="$(_attribution_trim "${_line}")"
        if _attribution_is_line "${_t}"; then
            printf '%s\n' "${_t}"
            _found=0
        fi
    done <<<"$1"
    return "${_found}"
}
