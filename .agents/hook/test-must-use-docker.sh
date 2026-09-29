#!/usr/bin/env bash
# .agents/hook/test-must-use-docker.sh - Claude Code PreToolUse hook
# (matcher: Bash), registered in .claude/settings.json.
#
# worktool rule (AGENTS.md, git conventions): tests run ONLY in Docker and
# only through the user interface `just test <tier>` (lint, unit,
# integration, system, acceptance, system-real; bare `just test` = all).
# The host never runs bats and never installs packages. This hook BLOCKS
# (exit 2) a Bash command that launches, on the host:
#   1. `bats` directly (also quoted, and behind cd / sudo / env / command /
#      timeout(1), with or without their options: sudo -u root, env -i)
#   2. script/test/test.sh directly - its host steps are what `just test`
#      forwards to, and its --ci-* flags are the container-side gates
#   3. a hand-rolled `docker run|exec ... bats` / `... test.sh` (the image,
#      mounts and required-spec checks belong to test.sh via `just test`)
#   4. a host package mutation: apt / apt-get install|remove|purge|upgrade
# and allows everything else, including `just test ...`.
#
# Only real launches count: the command is reduced to its sub-commands by
# lib/subcommand.sh (a quoted span is one opaque word and heredoc bodies
# are dropped, so a commit message or a spec being written may mention bats
# freely, while a quoted executable name is still seen).
#
# The command is read with jq when present, else with a small sed parser:
# this hook guards the host, where jq might be missing.
#
# Exit codes: 0 = allow, 2 = block (Claude Code shows stderr to the model).

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "test-must-use-docker"

# Print .tool_input.command of the payload (jq, else a sed fallback that
# does not handle escaped quotes inside the command - enough on the host).
_extract_cmd() {
    if command -v jq >/dev/null 2>&1; then
        hook_command
        return 0
    fi
    printf '%s' "${HOOK_INPUT}" \
        | sed -n 's/.*"command":[[:space:]]*"\(\([^"\\]*\|\\.\)*\)".*/\1/p' \
        | head -n 1
}

# Drop a leading timeout(1) / gtimeout wrapper with its options and duration.
_strip_timeout() {
    local _sub="$1"
    if [[ "${_sub}" =~ ^g?timeout([[:space:]]+-[^[:space:]]+)*[[:space:]]+[0-9][^[:space:]]*[[:space:]]+ ]]; then
        _sub="${_sub#"${BASH_REMATCH[0]}"}"
    fi
    printf '%s' "${_sub}"
}

# _violation <sub-command> - print why this launch breaks the rule, or
# nothing when it is fine.
_violation() {
    local _sub _first _second
    # timeout(1) is kept by the lib; a wrapper may sit on either side of it.
    _sub="$(_hook_strip_wrappers "$(_strip_timeout "$1")")"
    read -r _first _second _ <<<"${_sub}"
    [[ "${_first}" == bash || "${_first}" == sh ]] && _first="${_second}"
    case "${_first}" in
        bats|*/bats)
            printf "direct 'bats' on the host" ;;
        script/test/test.sh|*/script/test/test.sh)
            printf 'direct script/test/test.sh run instead of the just interface' ;;
        docker)
            if [[ "${_sub}" =~ (^|[[:space:]])(bats|[^[:space:]]*test/test\.sh)([[:space:]]|$) ]]; then
                printf 'hand-rolled docker test run instead of the just interface'
            fi ;;
        apt|apt-get)
            if [[ "${_second}" =~ ^(install|remove|purge|upgrade|dist-upgrade|full-upgrade)$ ]]; then
                printf 'host package mutation (%s %s)' "${_first}" "${_second}"
            fi ;;
    esac
}

main() {
    hook_read_input
    local _cmd _sub _why
    _cmd="$(_extract_cmd)"
    [[ -z "${_cmd}" ]] && hook_allow
    while IFS= read -r _sub; do
        _why="$(_violation "${_sub}")"
        [[ -z "${_why}" ]] && continue
        hook_block "${_why} - tests run only in Docker, through just." \
            "Command: ${_cmd}" \
            "Use: just test <tier>   (lint | unit | integration | system | acceptance | system-real; bare 'just test' runs all)" \
            "Never run bats, script/test/test.sh or package installs on the host (AGENTS.md)."
    done < <(hook_subcommands "${_cmd}")
    hook_allow
}

main "$@"
