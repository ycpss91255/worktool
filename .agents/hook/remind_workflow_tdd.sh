#!/usr/bin/env bash
# .agents/hook/remind_workflow_tdd.sh - Claude Code UserPromptSubmit hook,
# registered in .claude/settings.json. Advisory only: never blocks.
#
# Keeps worktool's standing delivery directive in context every turn, so
# the maintainer does not have to repeat it (AGENTS.md, doc/workflow.md):
# work splits into sub-issues, each delivered by the pr-loop workflow (or
# several independent ones by milestone-fanout) in its own worktree, TDD
# with the gates run through `just test <tier>` in Docker, one issue one
# PR one thing, merged with a merge commit only once CI is green and codex
# confirmed; the milestone acceptance PR is a human gate. The hook can only
# remind - choosing to fan out stays the agent's judgment.
#
# additionalContext (not systemMessage): it informs the agent without
# adding chat noise. The stdin prompt payload is read and ignored.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
hook_bootstrap "remind-workflow-tdd"

main() {
    hook_read_input
    hook_context \
        "Standing worktool directive (maintainer, do not re-ask): deliver each sub-issue through the pr-loop workflow (.claude/workflows/pr-loop.js; independent sub-issues together through milestone-fanout) in its own .worktree/<name>, TDD first (show RED, then GREEN), every gate run through 'just test <tier>' in Docker, never on the host. One issue = one PR = one thing; one commit per unit. Merge only after CI is green and codex confirmed, with a merge commit (no squash, no auto-merge); the milestone acceptance PR is a human gate. Issues/PRs/docs in zh-TW, commits and code in English. Solo (no workflow) only for trivial or conversational turns." \
        "UserPromptSubmit"
}

main "$@"
