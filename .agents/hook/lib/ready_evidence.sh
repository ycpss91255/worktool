#!/usr/bin/env bash
# Readiness policy, sourced by the hook; no shell options changed here.

ready_check_comment() {
    [[ "$1" =~ (就緒|已備妥|請(維護者)?驗收|待維護者驗收|[Rr]eady[[:space:]]+for[[:space:]]+(review|acceptance)) ]] || return 0
    local _repo _pr _json _sha _checks _target
    _target="$(ready_target)" || exit 2
    read -r _repo _pr <<<"${_target}"
    ready_is_pr "${_repo}" "${_pr}" || return 0
    _json="$(_gh pr view "${_pr}" --repo "${_repo}" --json number,labels,headRefOid,body)" \
        || hook_block 'PR query failed (fail closed)'
    if ! jq -e '.labels | type == "array"' <<<"${_json}" >/dev/null; then
        hook_block 'PR labels query is malformed (fail closed)'
    fi
    jq -e '.labels | any(.name == "milestone-gate")' <<<"${_json}" >/dev/null || return 0
    _pr="$(jq -er '.number | numbers | select(. > 0 and . == floor)' <<<"${_json}")" \
        || hook_block 'PR number query failed (fail closed)'
    _sha="$(jq -er '.headRefOid | strings | select(length > 0)' <<<"${_json}")" \
        || hook_block 'PR head query failed (fail closed)'
    _checks="$(_gh pr view "${_pr}" --repo "${_repo}" --json headRefOid,statusCheckRollup)" \
        || hook_block 'verify-all query failed (fail closed)'
    if ! jq -e --arg sha "${_sha}" '.headRefOid == $sha and
        ([.statusCheckRollup[] | select((.name? // "") | startswith("verify-all ("))] |
        (map(.name) | unique | contains(["verify-all (ubuntu-latest)", "verify-all (ubuntu-24.04-arm)"]))
        and all(.status == "COMPLETED" and .conclusion == "SUCCESS"))' <<<"${_checks}" >/dev/null; then
        hook_block 'verify-all on the current PR head must be success (missing or not successful)'
    fi
    ready_require_verdict "${_repo}" "${_pr}" "${_sha}"
    ready_require_table "$1"
    ready_require_goals "${_repo}" "${_json}" "$1"
}

ready_require_table() {
    printf '%s\n' "$1" | awk -v header_only=1 -f "${_READY_HERE}/lib/ready_table.awk" \
        || hook_block '缺少目標對照段落與表格'
}

ready_require_goals() {
    local _repo="$1" _pr_json="$2" _body="$3" _issue _json _goals _goal
    _issue="$(jq -r '.body // ""' <<<"${_pr_json}" | awk '
        match(tolower($0), /(closes|fixes|resolves)[[:space:]]+#[0-9]+/) {
            s=substr($0,RSTART,RLENGTH); sub(/.*#/,"",s); print s; exit
        }')"
    [[ "${_issue}" =~ ^[0-9]+$ ]] || hook_block 'cannot resolve milestone issue from PR closing reference (fail closed)'
    _json="$(_gh issue view "${_issue}" --repo "${_repo}" --json body)" \
        || hook_block 'milestone issue query failed (fail closed)'
    _goals="$(jq -er '.body | strings' <<<"${_json}" | awk -f "${_READY_HERE}/lib/ready_goals.awk")" \
        || hook_block 'cannot parse milestone goals (fail closed)'
    [[ -n "${_goals}" ]] || hook_block 'milestone issue has no readable goals (fail closed)'
    while IFS= read -r _goal; do
        printf '%s\n' "${_body}" | awk -v goal="${_goal}" -f "${_READY_HERE}/lib/ready_table.awk" \
            || hook_block "目標對照缺少目標、使用者實際入口、驗證項目或證據：${_goal}"
    done <<<"${_goals}"
}

ready_target() {
    local _repo _sel _path
    if [[ "$(_sub)" == api ]]; then
        _path="$(_api_path "$(_api_endpoint)")"
        [[ "${_path}" =~ ^repos/([^/]+/[^/]+)/(issues|pulls)/([0-9]+)/(comments|reviews) ]] \
            || hook_block 'cannot resolve readiness API target (fail closed)'
        printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
        return 0
    fi
    _sel="$(_positional "${_VALUE_OPTS}" "$((_ARG0 + 1))")" || _sel=''
    _repo="$(_opt -R --repo)" || _repo='ycpss91255/worktool'
    [[ -n "${_sel}" ]] || hook_block 'cannot resolve readiness PR (fail closed)'
    printf '%s %s\n' "${_repo}" "${_sel}"
}

ready_is_pr() {
    local _json
    # PR selectors can be branch names or URLs; issue targets are numeric.
    if [[ "$(_sub)" != issue\ * && "$(_sub)" != api ]]; then
        return 0
    fi
    _json="$(_gh api "repos/$1/issues/$2")" \
        || hook_block 'issue target query failed (fail closed)'
    if ! jq -e 'type == "object" and (.number | type == "number")' <<<"${_json}" >/dev/null; then
        hook_block 'issue target query is malformed (fail closed)'
    fi
    jq -e 'has("pull_request")' <<<"${_json}" >/dev/null
}

ready_require_verdict() {
    local _comments
    _comments="$(_gh api --paginate "repos/$1/issues/$2/comments")" \
        || hook_block 'codex verdict query failed (fail closed)'
    if ! jq -s -e --arg sha "$3" '
        if all(.[]; type == "array") then add else error("malformed pages") end |
        if all(.[]; (.body | type == "string") and
            (.created_at | fromdateiso8601 | type == "number")) then .
        else error("malformed comments") end |
        def verdict($word): .body | split("\n") | map(rtrimstr("\r")) |
            index("交出判定：" + $word + " head=" + $sha) != null;
        [ .[] | select((.body | test("^\\s*\\[codex\\](\\s|$)")) and verdict("可交出")) |
            .created_at | fromdateiso8601 ] as $positive |
        [ .[] | select(verdict("不可交出")) | .created_at | fromdateiso8601 ] as $negative |
        ($sha | test("^[0-9a-f]{40}$")) and ($positive | length > 0) and
        (($negative | length == 0) or (($positive | max) > ($negative | max)))' \
        <<<"${_comments}" >/dev/null; then
        hook_block 'codex handover verdict required (fail closed)'
    fi
}
