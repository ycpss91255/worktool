#!/usr/bin/env bash
# Readiness policy, sourced by the hook; no shell options changed here.

ready_check_comment() {
    [[ "$1" =~ (就緒|請驗收|待維護者驗收|ready[[:space:]]+for[[:space:]]+(review|acceptance)) ]] || return 0
    local _sel _repo _pr _json _sha _checks
    _sel="$(_positional "${_VALUE_OPTS}" "$((_ARG0 + 1))")" || _sel=''
    _repo="$(_opt -R --repo)" || _repo=''
    [[ "${_sel}" =~ ^[0-9]+$ && -n "${_repo}" ]] || hook_block 'cannot resolve readiness PR (fail closed)'
    _pr="${_sel}"
    _json="$(_gh api --repo "${_repo}" "repos/${_repo}/pulls/${_pr}")" \
        || hook_block 'PR query failed (fail closed)'
    jq -e '.labels | any(.name == "milestone-gate")' <<<"${_json}" >/dev/null || return 0
    _sha="$(jq -er '.head.sha' <<<"${_json}")"
    _checks="$(_gh api --repo "${_repo}" "repos/${_repo}/commits/${_sha}/check-runs")" \
        || hook_block 'verify-all query failed (fail closed)'
    if ! jq -e '[.check_runs[] | select(.name == "verify-all")] |
        length > 0 and all(.status == "completed" and .conclusion == "success")' <<<"${_checks}" >/dev/null; then
        hook_block 'verify-all on the current PR head must be success (missing or not successful)'
    fi
    ready_require_table "$1"
    ready_require_goals "${_repo}" "${_json}" "$1"
}

ready_require_table() {
    [[ "$1" =~ (^|$'\n')##[[:space:]]+目標對照($|$'\n') && "$1" == *'| 目標 |'* ]] \
        || hook_block '缺少目標對照段落與表格'
}

ready_require_goals() {
    local _repo="$1" _pr_json="$2" _body="$3" _issue _json _goals _goal
    _issue="$(jq -r '.body // ""' <<<"${_pr_json}" | awk '
        match(tolower($0), /(closes|fixes|resolves)[[:space:]]+#[0-9]+/) {
            s=substr($0,RSTART,RLENGTH); sub(/.*#/,"",s); print s; exit
        }')"
    [[ "${_issue}" =~ ^[0-9]+$ ]] || hook_block 'cannot resolve milestone issue from PR closing reference (fail closed)'
    _json="$(_gh api --repo "${_repo}" "repos/${_repo}/issues/${_issue}")" \
        || hook_block 'milestone issue query failed (fail closed)'
    _goals="$(jq -er '.body | strings' <<<"${_json}" | awk -f "${_READY_HERE}/lib/ready_goals.awk")" \
        || hook_block 'cannot parse milestone goals (fail closed)'
    [[ -n "${_goals}" ]] || hook_block 'milestone issue has no readable goals (fail closed)'
    while IFS= read -r _goal; do
        printf '%s\n' "${_body}" | awk -v goal="${_goal}" -f "${_READY_HERE}/lib/ready_table.awk" \
            || hook_block "目標對照缺少目標、驗證項目或使用者入口：${_goal}"
    done <<<"${_goals}"
}
