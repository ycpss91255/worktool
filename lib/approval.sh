#!/usr/bin/env bash
# lib/approval.sh - milestone-gate approval predicate (issue #187).
#
# A milestone acceptance PR carries the `milestone-gate` label and may be
# merged only after the maintainer records an approval on the PR itself.
# An approval is a comment whose author_association is OWNER, whose body
# (leading whitespace ignored) does not start with an agent marker
# (`[claude]` or `[codex]`), and whose body contains the phrase 允許合併.
# A PR without the label is not an acceptance PR and always passes.
#
# The predicate is pure: it takes plain data and makes no GitHub API call,
# so the CI workflow (.github/workflows/milestone-gate.yml) and an
# agent-side hook (issue #190) can share it; fetching the data is the
# caller's job.
#
# Public API:
#   approval_phrase
#       -> prints the approval phrase (no newline), for a caller that must
#          find it in text without restating it.
#   approval_is_human_approval <author_association> <body>
#       -> 0 when that one comment is a human approval, 1 otherwise.
#   approval_evaluate <labels>   (comment records on stdin)
#       <labels>: the PR's label names, one per line.
#       stdin: one record per comment, `<author_association>\t<body>`,
#       each terminated by NUL (bodies may hold newlines and tabs; the last
#       terminator may be missing). Read only when the label is present.
#       -> exit 0 = pass, 1 = fail; one zh-TW reason line on stdout either
#       way (fit for a commit status description).
#
# This is a library: it defines functions and must be sourced, not
# executed. It sets no shell options and prints nothing at source time.

# The phrase an approval must contain.
_approval_phrase() {
    printf '%s' '允許合併'
}

approval_phrase() {
    _approval_phrase
}

# 0 when the newline-separated label list $1 has `milestone-gate` exactly.
_approval_has_gate_label() {
    local _label
    while IFS= read -r _label; do
        [[ "${_label}" == 'milestone-gate' ]] && return 0
    done <<< "$1"
    return 1
}

approval_is_human_approval() {
    local _assoc="$1" _body="$2"
    [[ "${_assoc}" == 'OWNER' ]] || return 1
    # Ignore leading whitespace so ` [claude]` cannot pass as human.
    _body="${_body#"${_body%%[![:space:]]*}"}"
    case "${_body}" in
        '[claude]'* | '[codex]'*) return 1 ;;
    esac
    [[ "${_body}" == *"$(_approval_phrase)"* ]]
}

approval_evaluate() {
    local _assoc _body
    if ! _approval_has_gate_label "$1"; then
        printf '%s\n' '非 milestone 驗收 PR(未貼 milestone-gate),不需核准'
        return 0
    fi
    while IFS=$'\t' read -r -d '' _assoc _body || [[ -n "${_assoc}" ]]; do
        if approval_is_human_approval "${_assoc}" "${_body}"; then
            printf '%s\n' "已有維護者核准留言($(_approval_phrase))"
            return 0
        fi
        _assoc='' _body=''
    done
    printf '%s\n' "需要維護者留言:$(_approval_phrase)"
    return 1
}

# approval_has_agent_marker <agent> <body> - exact own marker after whitespace.
approval_has_agent_marker() {
    local _agent="$1" _body="$2"
    case "${_agent}" in claude|codex|agy|gemini) ;; *) return 1 ;; esac
    _body="${_body#"${_body%%[![:space:]]*}"}"
    [[ "${_body}" == "[${_agent}]"* ]]
}
