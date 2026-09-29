#!/usr/bin/env bash
# .agents/hook/enforce_long_job_timeout.sh - Claude Code PreToolUse hook
# (matcher: Bash), registered in .claude/settings.json.
#
# A long local job must not run as an unbounded FOREGROUND command: if it
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
# Exit codes: 0 = allow, 2 = block.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
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

main() {
    hook_read_input
    local _cmd _sub
    _cmd="$(hook_command)"
    [[ -z "${_cmd}" ]] && hook_allow
    [[ "$(hook_field '.tool_input.run_in_background')" == true ]] && hook_allow
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
