#!/usr/bin/env bash
# .agents/hook/remind_no_emoji.sh - Claude Code UserPromptSubmit hook,
# registered in .claude/settings.json. Advisory only: never blocks.
#
# Standing rule (AGENTS.md, language): no emoji anywhere - chat replies,
# commit messages, issue / PR titles, bodies and comments, code, docs. A
# hook cannot inspect the agent's prose, so this keeps the rule in context
# every turn. The stdin prompt payload is read and ignored.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
hook_bootstrap "remind-no-emoji"

main() {
    hook_read_input
    hook_context \
        "Standing style rule (maintainer, do not re-ask): NEVER use emoji anywhere - not in chat replies, commit messages, issue/PR titles, bodies or comments, code, or docs. Plain text only. (Functional symbols such as arrows or box-drawing in terminal output are fine; decorative emoji are not.)" \
        "UserPromptSubmit"
}

main "$@"
