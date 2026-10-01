#!/usr/bin/env bash
# .agents/hook/lib/hook_bootstrap.sh - shared bootstrap for the Claude Code
# hooks in .agents/hook/ (reached by Claude Code as .claude/hook/<name>.sh,
# a relative symlink; see .claude/settings.json).
#
# Every hook needs the same plumbing: read the tool-call JSON from stdin,
# pull a field out with jq, then either allow (exit 0) or print a
# "[hook:<name>] BLOCKED - ..." line to stderr and block (exit 2). This lib
# centralizes it so a hook collapses to: source this, read input, decide,
# call hook_allow / hook_block / hook_context.
#
# Hooks are exit-code-contract scripts - Claude Code reads the exit code
# (0 = allow, 2 = block) - so hook_bootstrap turns on `set -uo pipefail`
# and NOT -e: a conditional probe (`[[ ]]`, `grep -q`, a regex match)
# legitimately returns 1 without aborting the decision flow.
#
# The lib lives inside this repo and self-locates from its own file; it
# never honors a LIB_DIR from the environment (worktool's own lib/ is a
# different directory, and the test helper exports LIB_DIR for it).
#
# Public API (all prefixed `hook_`):
#   hook_bootstrap [name]   set -uo pipefail + HOOK_LIB_DIR / HOOK_REPO_ROOT
#                           + HOOK_NAME (default: script basename minus .sh)
#   hook_read_input         read the stdin JSON payload once into HOOK_INPUT
#   hook_field <jq-filter>  echo a field of HOOK_INPUT via jq (empty if absent
#                           or jq is missing)
#   hook_command            shorthand for the Bash tool's .tool_input.command
#   hook_worktree_root <r>  print the shared worktree root beside repo <r>
#   hook_allow              standard pass path: exit 0
#   hook_block <reason>...  standard block path: "[hook:<name>] BLOCKED" + exit 2
#   hook_context <msg> [ev] non-blocking: emit additionalContext JSON + exit 0
#
# This is a library: it is sourced, sets no shell options at source time and
# only declares functions plus the two state globals below.

# Library guard: refuse to run as an executable script.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    printf 'Warn: %s is a library, not an executable script.\n' "${BASH_SOURCE[0]##*/}"
    printf 'Source it from a hook, e.g.: source "%s"\n' "${BASH_SOURCE[0]:-}"
    return 0 2>/dev/null
fi

# State: the hook's display name (for block messages) and the raw payload.
HOOK_NAME="${HOOK_NAME:-hook}"
HOOK_INPUT="${HOOK_INPUT:-}"

# hook_bootstrap [name] - exit-code-contract strict mode + path resolution.
#   1. set -uo pipefail (deliberately NOT -e).
#   2. HOOK_LIB_DIR = this file's directory; HOOK_REPO_ROOT = three levels
#      up (.agents/hook/lib -> repo root). Both resolved physically, so a
#      hook reached through the .claude/hook symlink lands in the same repo.
#   3. HOOK_NAME = $1, else the script basename minus .sh.
hook_bootstrap() {
    set -uo pipefail

    HOOK_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    HOOK_REPO_ROOT="$(cd -- "${HOOK_LIB_DIR}/../../.." && pwd -P)"
    # Exported for the hook's own child processes (git, jq, helpers).
    export HOOK_LIB_DIR HOOK_REPO_ROOT

    local _name="${1:-}"
    if [[ -z "${_name}" ]]; then
        _name="${0##*/}"
        _name="${_name%.sh}"
    fi
    HOOK_NAME="${_name}"
}

# hook_read_input - read the hook JSON payload from stdin ONCE.
hook_read_input() {
    HOOK_INPUT="$(cat)"
}

# hook_field <jq-filter> - echo a field of HOOK_INPUT, or nothing when jq is
# missing or the field is absent / null. Never aborts the caller.
hook_field() {
    local _filter="${1:?hook_field needs <jq-filter>}"
    command -v jq >/dev/null 2>&1 || return 0
    printf '%s' "${HOOK_INPUT}" | jq -r "${_filter} // empty" 2>/dev/null
}

# hook_command - shorthand for the Bash tool's command string.
hook_command() {
    hook_field '.tool_input.command'
}

# hook_worktree_root <repo-root> - worktrees and their scratch space live in
# the worktree/ directory beside the main checkout.
hook_worktree_root() {
    local _repo_root="${1:?hook_worktree_root needs <repo-root>}"
    printf '%s/worktree' "$(dirname -- "${_repo_root}")"
}

# hook_allow - the standard pass path.
hook_allow() {
    exit 0
}

# hook_block <reason> [detail ...] - the standard block path: the reason and
# each detail line on stderr, prefixed with the hook name, then exit 2
# (Claude Code shows stderr to the model and denies the tool call).
hook_block() {
    local _reason="${1:?hook_block needs <reason>}"
    shift
    printf '[hook:%s] BLOCKED - %s\n' "${HOOK_NAME}" "${_reason}" >&2
    local _line
    for _line in "$@"; do
        printf '[hook:%s] %s\n' "${HOOK_NAME}" "${_line}" >&2
    done
    exit 2
}

# hook_context <message> [event-name] - the non-blocking path: emit a
# hookSpecificOutput.additionalContext object (event default PreToolUse)
# and exit 0. For reminder hooks that inform without deciding.
hook_context() {
    local _msg="${1:?hook_context needs <message>}"
    local _event="${2:-PreToolUse}"
    jq -n --arg m "${_msg}" --arg e "${_event}" '{
        hookSpecificOutput: { hookEventName: $e, additionalContext: $m }
    }'
    exit 0
}
