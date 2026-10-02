#!/usr/bin/env bash
# Claude/Codex PreToolUse Bash hook: allow = 0, refuse = 2.
# Claude Code supplies agent_id only on subagent tool calls; any nonempty
# string ID permits execution (including Workflow agents), per PR #372.
# Source checked 2026-10-02: https://code.claude.com/docs/en/hooks#common-input-fields
# No transcripts are read. Fixtures use the documented input schema.
# Registered after #364 / PR #369 merged; settings loading enables the hook.
# Main-session wrappers are read recursively (literal paths, depth < 16).
# Missing/opaque wrappers, expansions, eval, xargs, launcher chains and
# non-shell interpreters fail closed. Unchecked raw Codex mentions block,
# even in plain text. PATH-only executables/custom just recipes and encoded
# or runtime-generated calls remain outside static inspection. This is a
# cooperating-agent guard, not an OS sandbox or agent authentication.
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

# Identity contract: Claude Code supplies agent_id on subagent tool calls.
# Source checked 2026-10-02: https://code.claude.com/docs/en/hooks#common-input-fields
# Accept any subagent (including Workflow agents), as decided in PR #372.
# No transcript or environment markers are consulted. Empty/invalid IDs
# grant no exception; this cooperating-agent guard cannot authenticate input.
subagent_call() {
    jq -e '.agent_id | type == "string" and length > 0' \
        <<<"${HOOK_INPUT}" >/dev/null 2>&1
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
    local text="$1" re='(^|[^[:alnum:]_.-])(eval|xargs|setsid|busybox|nice|stdbuf|chroot)([^[:alnum:]_.-]|$)'
    if [[ "$(raw_codex_count "${text}")" -gt 0 && "${text}" =~ ${re} ]]; then
        refuse 'Indirect execution cannot be checked statically.'
    fi
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
        if [[ "$(raw_codex_count "$1")" -gt 0 ]] && hook_is_interpreter "${tool}"; then
            refuse 'Interpreter execution cannot be checked as a shell wrapper.'
        fi
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
subagent_call && hook_allow
check_command "$(hook_command)" "$(hook_field '.cwd')"
hook_allow
