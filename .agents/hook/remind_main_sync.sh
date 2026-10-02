#!/usr/bin/env bash
# .agents/hook/remind_main_sync.sh - Claude Code PreToolUse hook (matcher:
# Bash), registered in .claude/settings.json. Advisory only: never blocks.
#
# Fires before a real `gh pr merge` and injects a reminder to
# `git pull --ff-only origin main` on the main checkout afterwards, so local
# main keeps tracking origin/main instead of freezing behind (a stale main
# becomes a stale worktree base; check_main_fresh_before_worktree.sh
# catches that later, this hook prevents it).
#
# worktool merge policy (AGENTS.md, doc/workflow.md): a sub-issue PR is
# merged with a merge commit (`gh pr merge --merge`) once CI is green and
# codex confirmed - never squashed or rebased, so every agent's commits are
# kept - and nothing is queued with `--auto`. A `--squash` / `--rebase`
# merge or an `--auto` queue gets a note saying so. Variants:
#   queued     `--auto`: the merge lands later; pull once it has
#   immediate  otherwise: pull right after
#
# Only a real subcommand triggers it: launches are parsed first, so
# a commit message mentioning `gh pr merge` stays silent.
#
# PostToolUse runs cleanup only on confirmed successful immediate merges.
# Exit: always 0 (advisory JSON on stdout when it fires).

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
hook_bootstrap "remind-main-sync"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"

# _policy_note <cleaned-command> - worktool's merge-mode note, or nothing.
_policy_note() {
    local _note=''
    if [[ "$1" =~ --(squash|rebase)([[:space:]]|$) || "$1" =~ (^|[[:space:]])-[sr]([[:space:]]|$) ]]; then
        _note+=" Note: worktool merges with a merge commit (gh pr merge --merge) to keep every agent's commits; do not squash or rebase."
    fi
    if [[ "$1" =~ --auto([[:space:]]|$) ]]; then
        _note+=" Note: worktool does not queue auto-merges; merge only after CI is green and codex confirmed (the milestone acceptance PR is a human gate)."
    fi
    printf '%s' "${_note}"
}

_merge_succeeded() {
    # PostToolUse is a success event; Claude Bash has no exit_code field.
    jq -e '.tool_response as $r |
        if ($r | has("exit_code")) then $r.exit_code == 0
        else ($r.stdout | type) == "string" and
             ($r.stderr | type) == "string" and $r.interrupted == false
        end' <<< "${HOOK_INPUT}" >/dev/null 2>&1
}

_post_merge() {
    local command="$1" cwd report rc=0
    [[ "${command}" =~ --auto([[:space:]]|$) ]] && return 0
    [[ "${command}" =~ (^|[[:space:]])(--help|-h)([[:space:]]|$) ]] && return 0
    _merge_succeeded || return 0
    cwd="$(hook_field '.cwd')"
    cwd="${cwd:-${CLAUDE_PROJECT_DIR:-${HOOK_REPO_ROOT}}}"
    if ! report="$(cd -- "${cwd}" && ./.agents/script/worktree/prune-merged.sh --apply 2>&1)"; then
        rc=1
    fi
    printf '%s\n' "${report}" >&2
    if [[ "${rc}" == 1 ]]; then
        report="Worktree cleanup failed: ${report}"
    fi
    if ! jq -n --arg m "${report}" '{
        systemMessage: $m,
        hookSpecificOutput: {hookEventName:"PostToolUse", additionalContext:$m}
    }'; then
        printf '[hook:%s] cannot emit cleanup report\n' "${HOOK_NAME}" >&2
    fi
    return 0
}

main() {
    hook_read_input
    local _cmd _clean _sub _variant _msg
    _cmd="$(hook_command)"
    [[ -z "${_cmd}" ]] && return 0
    _clean=''
    while IFS= read -r _sub; do
        [[ "${_sub}" =~ ^gh([[:space:]]+(--repo|-R)[[:space:]]+[^[:space:]]+)?[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]] || continue
        _clean="${_sub}"
        break
    done < <(hook_subcommands "${_cmd}")
    [[ -n "${_clean}" ]] || return 0

    if [[ "$(hook_field '.hook_event_name')" == PostToolUse ]]; then
        _post_merge "${_clean}"
        return 0
    fi

    if [[ "${_clean}" =~ --auto([[:space:]]|$) ]]; then
        _variant=queued
        _msg="Auto-merge queued. Once GitHub completes the merge, run \`git pull --ff-only origin main\` on the main checkout so local main keeps tracking origin/main."
    else
        _variant=immediate
        _msg="PR merged. Run \`git pull --ff-only origin main\` on the main checkout now so local main keeps tracking origin/main (do not let it freeze behind)."
    fi
    _msg+="$(_policy_note "${_clean}")"

    if ! jq -n --arg m "${_msg}" --arg v "${_variant}" '{
        systemMessage: $m,
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            additionalContext: ($m + " [variant=" + $v + "]")
        }
    }'; then
        printf '[hook:%s] cannot emit advisory reminder\n' "${HOOK_NAME}" >&2
    fi
    return 0
}

main "$@"
