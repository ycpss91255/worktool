#!/usr/bin/env bash
# Claude PreToolUse Bash hook. Allow = 0; refuse = 2, diagnostics on stderr.
# Registration is deferred until #364 merges; see doc/workflow.md.
# This is a cooperating-agent guard, not an operating-system sandbox.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-codex-via-workflow"

refuse() {
    hook_block "$1" 'Use pr-loop / milestone-fanout for implementation.'
}

# Workflow agents carry a marker at the START of their first user task.
# Claude supplies transcript_path; require its subagents/agent-*.jsonl shape
# as well. A main transcript, ordinary Agent, environment assignment or
# marker in an assistant/tool message is insufficient. Templates emit the
# marker; this does not authenticate a hostile process forging transcripts.
workflow_agent() {
    local path prompt
    path="$(hook_field '.transcript_path')"
    [[ "${path}" == */subagents/agent-*.jsonl && -r "${path}" ]] || return 1
    prompt="$(jq -sr '
        [ .[] | select(.type == "user" and .message.role == "user") ][0].message.content
        | if type == "string" then .
          elif type == "array" then map(select(.type == "text") | .text) | join("\n")
          else "" end' "${path}" 2>/dev/null)" || return 1
    case "${prompt%%$'\n'*}" in
        'WORKTOOL_WORKFLOW_AGENT: pr-loop'|'WORKTOOL_WORKFLOW_AGENT: discuss'|'WORKTOOL_WORKFLOW_AGENT: research-verify') return 0 ;;
        *) return 1 ;;
    esac
}

# Only the explicit read-only sandbox is a main-loop exception. Unknown
# options and configuration overrides cannot silently grant write access.
readonly_launch() {
    local word value sandbox='' i positional=0
    local -a args=()
    for word in "$@"; do
        hook_word_has_expansion "${word}" && return 1
        args+=("$(hook_word "${word}")")
    done
    [[ "${args[1]:-}" == exec || "${args[1]:-}" == e ]] || return 1
    for ((i = 2; i < ${#args[@]}; i++)); do
        word="${args[i]}"
        case "${word}" in
            --sandbox|-s)
                i=$((i + 1)); value="${args[i]:-}"
                [[ "${value}" == read-only ]] || return 1
                sandbox=1 ;;
            --sandbox=read-only|-sread-only) sandbox=1 ;;
            --skip-git-repo-check|--json|--ephemeral) ;;
            -C|--cd|-o|--output-last-message|-m|--model)
                i=$((i + 1)); [[ -n "${args[i]:-}" ]] || return 1 ;;
            --) break ;;
            -) positional=$((positional + 1)) ;;
            -*) return 1 ;;
            *) positional=$((positional + 1)) ;;
        esac
    done
    [[ -n "${sandbox}" && "${positional}" -le 1 ]]
}

# Raw-text backstop: launches hidden in inline code/data are not credited
# as checked. As in the approval hook, mere mentions can also be refused.
raw_codex_count() {
    local rc=0 count
    count="$(grep -oE "(^|[^[:alnum:]_.-])codex([[:space:]\"']|$)" <<<"$1" | wc -l)" || rc=$?
    (( rc <= 1 )) || refuse 'Cannot count Codex mentions.'
    printf '%s' "${count}"
}

closed_command() {
    local text="$1" re='(^|[^[:alnum:]_.-])(eval|xargs)([^[:alnum:]_.-]|$)'
    [[ "${text}" =~ ${re} ]] && refuse 'Indirect execution cannot be checked statically.'
    return 0
}

inspect_wrapper() {
    local path="$1" cwd="$2" depth="$3"
    [[ "${path}" == /* ]] || path="${cwd}/${path}"
    [[ -f "${path}" && -r "${path}" ]] || refuse 'Cannot read a wrapper script.'
    check_command "$(cat -- "${path}")" "${cwd}" "$((depth + 1))"
}

check_command() {
    local sub lead tool path checked=0
    local cwd="$2" depth="${3:-0}"
    (( depth < 16 )) || refuse 'Wrapper nesting exceeds the static inspection limit.'
    local -a words
    closed_command "$1"
    while IFS= read -r sub; do
        lead="$(hook_timeout_lead "${sub}")"
        read -r -a words <<<"${sub#"${lead}"}"
        hook_word_has_expansion "${words[0]:-}" && refuse 'An expanded executable cannot be checked.'
        tool="$(hook_word "${words[0]:-}")"
        if [[ "${tool}" == cd ]]; then
            path="$(hook_word "${words[1]:-}")"
            [[ "${path}" == /* ]] || path="${cwd}/${path}"
            cwd="${path}"
            continue
        fi
        if [[ "${tool##*/}" == codex ]]; then
            readonly_launch "${words[@]}" || refuse 'Main-loop codex execution must go through a Workflow.'
            checked=$((checked + 1))
            continue
        fi
        path=""
        hook_is_interpreter "${tool}" && refuse 'Interpreter execution cannot be checked as a shell wrapper.'
        case "${tool##*/}" in
            bash|sh|dash|zsh|ksh|fish|source|.)
                hook_word_has_expansion "${words[1]:-}" && refuse 'An expanded script path cannot be checked.'
                path="$(hook_word "${words[1]:-}")"
                [[ -n "${path}" ]] || refuse 'A shell script without a literal path cannot be checked.' ;;

            *) [[ "${tool}" == */* || "${tool}" == *.sh ]] && path="${tool}" ;;
        esac
        if [[ -n "${path}" ]]; then
            inspect_wrapper "${path}" "${cwd}" "${depth}"
        fi
    done < <(hook_subcommands_raw "$1")
    [[ "$(raw_codex_count "$1")" -le "${checked}" ]] || refuse 'An unchecked Codex mention may hide an indirect launch.'
}

hook_read_input
workflow_agent && hook_allow
check_command "$(hook_command)" "$(hook_field '.cwd')"
hook_allow
