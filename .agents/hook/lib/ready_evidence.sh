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
    if jq -e '.check_runs | any(.name == "verify-all" and .conclusion != "success")' <<<"${_checks}" >/dev/null; then
        hook_block 'verify-all on the current PR head must be success'
    fi
}
