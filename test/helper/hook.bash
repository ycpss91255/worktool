#!/usr/bin/env bash
# test/helper/hook.bash - shared helpers for the Claude Code hook specs
# (test/unit/hook/*.bats).
#
# Loaded after common.bash:
#   load "${BATS_TEST_DIRNAME}/../../helper/common"
#   load "${BATS_TEST_DIRNAME}/../../helper/hook"
#
# Provides:
#   HOOK_DIR               the hooks' real directory (.agents/hook; the
#                          .claude/hook symlink that settings.json uses is
#                          covered by test/unit/agent_config_spec.bats)
#   hook_json <command>    a PreToolUse Bash payload for <command>
#   run_hook <hook> <json> feed <json> to .agents/hook/<hook>.sh on stdin,
#                          the way Claude Code invokes it (bats `run`)

HOOK_DIR="${REPO_ROOT}/.agents/hook"
export HOOK_DIR

hook_json() {
    jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'
}

# The payload and the hook path travel as positional arguments, never
# interpolated into the command string, so quotes or globs inside the
# command under test cannot break the harness.
run_hook() {
    run bash -c 'printf "%s" "$1" | "$2"' _ "$2" "${HOOK_DIR}/$1.sh"
}

# disable_line <codes> - a ShellCheck disable directive for <codes> (e.g.
# SC2034,SC2317), assembled at run time so the fixture specs themselves
# carry no literal directive (worktool keeps zero of them).
disable_line() {
    printf '# %s %s=%s' shellcheck disable "$1"
}
