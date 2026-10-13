#!/usr/bin/env bash
# .agents/hook/enforce_long_job_timeout.sh - PreToolUse hook for both harnesses.
# (matcher: Bash), registered in .claude/settings.json and .codex/hooks.json.
#
# A Claude long local job must not run as an unbounded FOREGROUND command: if it
# hangs, the session waits forever. In worktool the long jobs are the
# test gates (`just test [tier]`, script/test/test.sh), the real box verbs
# (`just box assemble` / `bench` without --dry-run / --help), image builds
# and compose service runs. Each needs one of:
#   1. run_in_background: true   (the harness notifies on completion)
#   2. the Bash `timeout` param  (the OS reaps a hang at the deadline)
#   3. a self-wrapped timeout(1) / gtimeout leading that same launch
# Otherwise the hook BLOCKS (exit 2) with that guidance; a PreToolUse hook
# cannot rewrite the command, so "enforce" means block-with-guidance.
#
# Only real launches count: lib/subcommand.sh reduces the command to its
# sub-commands (a quoted span is one opaque word, heredoc bodies are
# dropped), and a sub-command led by a text carrier (git, gh, grep, echo,
# ...) is never a launch. The timeout(1) bound is judged per sub-command.
#
# Pure foreground waits/polling are blocked even with a time bound. Job
# result collection and harness background notifications are the shared
# alternatives. The pr-loop role delegates long gates and every wait to
# its separate workflow agent, regardless of timeout/background settings.
# Implementer inputs skip only Claude's time-bound requirement; their outer
# runner supplies the deadline. Source detection lives in the hook library.
# Exit codes: 0 = allow, 2 = block.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
# shellcheck source=long_job_timeout.sh
source "${_HOOK_HERE}/lib/long_job_timeout.sh"
hook_bootstrap "long-job-timeout"

# _self_wrapped <sub-command> - 0 when THIS sub-command is led by a
# `timeout`/`gtimeout [options] <duration>` wrapper. Judged per launch, so a
# timeout elsewhere (`echo timeout 1; just test unit`, `timeout 5 true &&
# ...`) bounds nothing. The lib keeps a multi-line quoted argument inside
# its sub-command, so the wrapper and the launch it bounds stay together.
_self_wrapped() {
    [[ "$1" =~ ^g?timeout[[:space:]]+(-[A-Za-z][A-Za-z-]*[[:space:]]+|--[A-Za-z][A-Za-z-]*([[:space:]]+|=)[^[:space:]]+[[:space:]]+)*[0-9] ]]
}

# _just_is_long <words...> - a `just test` gate (not its help) or a real
# `just box assemble|bench` (not --dry-run / --help).
_just_is_long() {
    local _w _i
    local -a _words=("$@")
    for ((_i = 1; _i < ${#_words[@]}; _i++)); do
        _w="${_words[_i]}"
        [[ "${_w}" == job ]] && return 1
        if [[ "${_w}" == test ]]; then
            [[ "${_words[_i + 1]:-}" =~ ^(help|h|--help|-h)$ ]] && return 1
            return 0
        fi
        if [[ "${_w}" == box ]]; then
            [[ "${_words[_i + 1]:-}" =~ ^(assemble|bench)$ ]] || return 1
            [[ " ${_words[*]} " =~ [[:space:]](--dry-run|--help|-h)[[:space:]] ]] && return 1
            return 0
        fi
    done
    return 1
}

# _is_long <sub-command> - 0 when the sub-command is a known long launch.
_is_long() {
    local -a _w
    read -ra _w <<<"$1"
    [[ "${_w[0]:-}" == bash || "${_w[0]:-}" == sh ]] && _w=("${_w[@]:1}")
    case "${_w[0]:-}" in
        just) _just_is_long "${_w[@]}" ;;
        script/test/test.sh|*/script/test/test.sh)
            [[ " ${_w[*]} " =~ [[:space:]](--help|-h)[[:space:]] ]] && return 1
            return 0 ;;
        docker)
            [[ "$1" =~ ^docker[[:space:]]+(build|buildx[[:space:]]+build)([[:space:]]|$) ]] && return 0
            [[ "$1" =~ ^docker[[:space:]]+compose[[:space:]].*[[:space:]]run([[:space:]]|$) ]] ;;
        *) return 1 ;;
    esac
}

# Pure waiting never earns a model turn, even when bounded.
_is_wait() {
    local -a w
    local arg
    read -ra w <<<"$1"
    case "${w[0]##*/}" in
        tail)
            for arg in "${w[@]:1}"; do
                [[ "$arg" == --pid* || "$arg" == --follow* || "$arg" =~ ^-[^-]*[fF] ]] && return 0
            done ;;
        watch) return 0 ;;
        sleep)
            local total=0 value
            for arg in "${w[@]:1}"; do
                [[ "$arg" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)s?$ ]] || return 0
                value="${arg%s}"
                total="$(awk -v a="$total" -v b="$value" 'BEGIN { print a+b }')"
            done
            awk -v n="$total" 'BEGIN { exit !(n <= 5) }' || return 0 ;;
    esac
    return 1
}

_poll_loop() {
    local script text sub has_loop
    while IFS= read -r -d '' script; do
        text="$(_hook_strip_heredocs "$script" | _hook_unquote)"
        has_loop='(^|[;&|()[:space:]])(while|until)[[:space:]]'
        [[ "$text" =~ $has_loop ]] || continue
        while IFS= read -r sub; do
            [[ "$sub" =~ ^(g?timeout[[:space:]]+[^[:space:]]+[[:space:]]+)?sleep[[:space:]] ]] && return 0
        done < <(hook_subcommands "$script")
    done < <(hook_scripts "$1")
    return 1
}

# A detached launch retains the role restrictions of its payload.
_role_job_forbidden() {
    local arg payload sub
    [[ "${1:-}" == wait ]] && return 0
    [[ "${1:-}" == start ]] || return 1
    shift
    while [[ $# -gt 0 ]]; do
        arg="$1"; shift
        [[ "$arg" == -- ]] || continue
        printf -v payload '%q ' "$@"
        while IFS= read -r sub; do
            _role_raw_forbidden "$sub" && return 0
        done < <(hook_subcommands_raw "$payload")
        return 1
    done
    return 1
}

_role_forbidden() {
    local -a w=("$@")
    [[ "${w[0]:-}" == bash || "${w[0]:-}" == sh ]] && w=("${w[@]:1}")
    case "${w[0]##*/}" in
        sleep) return 0 ;;
        test.sh)
            if [[ "${w[0]}" == script/test/test.sh || "${w[0]}" == */script/test/test.sh ]]; then
                local selector="${w[1]:-}"
                _role_forbidden just test "${selector#--}" "${w[@]:2}"
                return $?
            fi ;;
        job.sh) _role_job_forbidden "${w[@]:1}"; return $? ;;
        gh)
            [[ " $* " == *' --watch '* || " $* " == *' run watch '* ]] && return 0 ;;
        just)
            local i verb next
            for ((i=1; i<${#w[@]}; i++)); do
                verb="${w[i]}"; next="${w[i+1]:-}"
                case "$verb" in
                    job) _role_job_forbidden "${w[@]:i+1}"; return $? ;;
                    verify) [[ "$next" == all || "$next" == realbox ]] && return 0; return 1 ;;
                    box) _just_is_long "${w[@]}"; return $? ;;
                    test)
                        [[ "$next" =~ ^(lint|help|h|--help|-h)$ ]] && return 1
                        [[ "$next" == changed || -z "$next" ]] && return 0
                        # A tier alone, or only options, has no selected spec.
                        local arg
                        for arg in "${w[@]:i+2}"; do
                            [[ "$arg" == *.bats ]] && return 1
                        done
                        return 0 ;;
                esac
            done ;;
    esac
    [[ "${w[0]##*/}" == wait ]] && return 0
    _is_wait "${w[*]}"
}

# Keep quoted payload arguments intact until the job command is unpacked.
_role_raw_forbidden() {
    local raw="$1" lead token
    local -a encoded words=()
    lead="$(hook_timeout_lead "$raw")"
    read -ra encoded <<<"${raw#"$lead"}"
    for token in "${encoded[@]}"; do words+=("$(hook_word "$token")"); done
    _role_forbidden "${words[@]}"
}

main() {
    hook_read_input
    local _cmd _sub
    _cmd="$(hook_command)"
    [[ -z "${_cmd}" ]] && hook_allow
    if [[ "${WORKTOOL_AGENT_ROLE:-}" == pr-loop ]]; then
        while IFS= read -r _sub; do
            if _role_raw_forbidden "${_sub}"; then
                hook_block "pr-loop: delegate long gates and all waits to the workflow job stage."
            fi
        done < <(hook_subcommands_raw "${_cmd}")
        _poll_loop "${_cmd}" && hook_block "pr-loop: delegate polling to the workflow job stage."
    fi
    [[ "$(hook_field '.tool_input.run_in_background')" == true ]] && hook_allow
    if _poll_loop "${_cmd}"; then
        hook_block "foreground polling: use job.sh wait or run_in_background."
    fi
    while IFS= read -r _sub; do
        local lead
        lead="$(hook_timeout_lead "${_sub}")"
        if _is_wait "${_sub#"${lead}"}"; then
            hook_block "foreground waiting: use job.sh wait or run_in_background."
        fi
    done < <(hook_subcommands "${_cmd}")
    hook_implementer_input && hook_allow
    [[ "$(hook_field '.tool_input.timeout')" =~ ^[1-9][0-9]*$ ]] && hook_allow
    while IFS= read -r _sub; do
        _self_wrapped "${_sub}" && continue
        _is_long "${_sub}" || continue
        hook_block "long-running foreground command with no time bound." \
            "Command: ${_cmd}" \
            "Pick one:" \
            "  1. run_in_background: true   (harness notifies on completion)" \
            "  2. set the Bash \"timeout\" param, e.g. 600000 (OS reaps a hang at the deadline)" \
            "  3. self-wrap the command with timeout(1)"
    done < <(hook_subcommands "${_cmd}")
    hook_allow
}

main "$@"
