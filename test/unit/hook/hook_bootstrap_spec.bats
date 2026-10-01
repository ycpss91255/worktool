#!/usr/bin/env bats
# test/unit/hook/hook_bootstrap_spec.bats - .agents/hook/lib/hook_bootstrap.sh
#
# The shared bootstrap every Claude Code hook under .agents/hook/ sources
# (issue #189: the hooks and their lib live in this repo, nothing is
# sourced from another checkout). Pins the public contract through real
# behaviour:
#   - the lib refuses to run as a top-level script (library guard)
#   - hook_bootstrap turns on the exit-code-contract strict mode (set -u +
#     pipefail and -e) and self-locates HOOK_LIB_DIR / HOOK_REPO_ROOT from
#     its own file - a LIB_DIR in the environment (the worktool test helper
#     exports one for lib/) never redirects it
#   - hook_read_input / hook_command / hook_field parse the stdin payload
#   - hook_allow exits 0; hook_block prints "[hook:<name>] BLOCKED - ..." to
#     stderr and exits 2
#   - hook_context emits a non-blocking additionalContext object, exit 0

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    HOOK_LIB="${REPO_ROOT}/.agents/hook/lib"
    SNIPPET="${BATS_TEST_TMPDIR}/snippet.sh"
    HOOKF="${BATS_TEST_TMPDIR}/fixture-hook.sh"
}

# Feed a command's payload to the fixture hook on stdin.
_run() {
    run bash -c 'printf "%s" "$1" | "$2"' _ "$(hook_json "$1")" "${HOOKF}"
}

# Write the fixture hook: source the bootstrap, then the body read from
# stdin (a quoted heredoc at every call site, so nothing expands early).
_write_hook() {
    {
        printf '#!/usr/bin/env bash\nsource "%s/hook_bootstrap.sh"\n' "${HOOK_LIB}"
        cat
    } >"${HOOKF}"
    chmod +x "${HOOKF}"
}

# A reference decider hook: read input, decide, allow / block.
_write_decider() {
    _write_hook <<'EOF'
hook_bootstrap "myhook"
hook_read_input
cmd="$(hook_command)"
[[ -z "${cmd}" ]] && hook_allow
[[ "${cmd}" == *bad* ]] && hook_block "bad command detected" "do X instead"
hook_allow
EOF
}

@test "hook_bootstrap.sh parses (bash -n)" {
    run bash -n "${HOOK_LIB}/hook_bootstrap.sh"
    assert_success
}

@test "hook_bootstrap.sh refuses to run as a top-level script (library guard)" {
    run bash "${HOOK_LIB}/hook_bootstrap.sh"
    assert_success
    assert_output --partial "is a library"
}

@test "sourcing hook_bootstrap.sh defines the public hook_* API" {
    cat >"${SNIPPET}" <<'EOF'
source "$1/hook_bootstrap.sh"
for f in hook_bootstrap hook_read_input hook_field hook_command hook_allow hook_block hook_context; do
    declare -F "$f" >/dev/null || { echo "missing $f"; exit 1; }
done
echo ALL_DEFINED
EOF
    run bash "${SNIPPET}" "${HOOK_LIB}"
    assert_success
    assert_output "ALL_DEFINED"
}

@test "hook_bootstrap stops after an unexpected failure with errexit" {
    cat >"${SNIPPET}" <<'EOF'
source "$1/hook_bootstrap.sh"
hook_bootstrap snip
[[ "$-" == *u* ]] && echo HAS_U
[[ "$-" == *e* ]] && echo HAS_E
set -o | grep -q "pipefail.*on" && echo HAS_PIPEFAIL
false
echo UNREACHABLE
EOF
    run bash "${SNIPPET}" "${HOOK_LIB}"
    assert_failure 1
    assert_output --partial "HAS_U"
    assert_output --partial "HAS_E"
    refute_output --partial "UNREACHABLE"
    assert_output --partial "HAS_PIPEFAIL"
}

@test "hook_bootstrap self-locates its lib and the repo root, ignoring an env LIB_DIR" {
    cat >"${SNIPPET}" <<'EOF'
source "$1/hook_bootstrap.sh"
hook_bootstrap snip
printf 'LIB=%s\nROOT=%s\n' "${HOOK_LIB_DIR}" "${HOOK_REPO_ROOT}"
EOF
    LIB_DIR=/nowhere run bash "${SNIPPET}" "${HOOK_LIB}"
    assert_success
    assert_line "LIB=${HOOK_LIB}"
    assert_line "ROOT=${REPO_ROOT}"
}

@test "hook_bootstrap names the hook after its script when no name is given" {
    _write_hook <<'EOF'
hook_bootstrap
printf 'NAME=%s\n' "${HOOK_NAME}"
EOF
    _run "ls"
    assert_success
    assert_output "NAME=fixture-hook"
}

@test "hook_command extracts .tool_input.command from the stdin payload" {
    _write_hook <<'EOF'
hook_bootstrap echocmd
hook_read_input
printf 'CMD=[%s]\n' "$(hook_command)"
EOF
    _run "git push origin main"
    assert_success
    assert_output "CMD=[git push origin main]"
}

@test "hook_field returns empty for an absent field" {
    _write_hook <<'EOF'
hook_bootstrap fieldtest
hook_read_input
printf 'CWD=[%s]\n' "$(hook_field .cwd)"
EOF
    _run "ls"
    assert_success
    assert_output "CWD=[]"
}

@test "hook_block blocks with exit 2 and the standard message" {
    _write_decider
    _run "run something bad now"
    assert_failure 2
    assert_output --partial "[hook:myhook] BLOCKED"
    assert_output --partial "bad command detected"
    assert_output --partial "do X instead"
}

@test "hook_allow allows an unrelated command (exit 0, no block message)" {
    _write_decider
    _run "ls -la"
    assert_success
    refute_output --partial "BLOCKED"
}

@test "an empty command is allowed (exit 0)" {
    _write_decider
    _run ""
    assert_success
    refute_output --partial "BLOCKED"
}

@test "hook_context emits additionalContext JSON for the given event and exits 0" {
    _write_hook <<'EOF'
hook_bootstrap ctx
hook_read_input
hook_context "remember to sync" UserPromptSubmit
EOF
    _run "anything"
    assert_success
    run jq -r '.hookSpecificOutput | .hookEventName + "|" + .additionalContext' <<<"${output}"
    assert_output "UserPromptSubmit|remember to sync"
}

@test "malformed input leaves hook_field empty and allows the decider" {
    _write_hook <<'EOF'
hook_bootstrap fieldtest
HOOK_INPUT='invalid json'
value="$(hook_field .cwd)"
[[ -z "${value}" ]] || hook_block "unexpected value"
hook_allow
EOF
    _run "anything"
    assert_success
    assert_output ""
}

@test "advisory context exits zero when jq cannot emit JSON" {
    _write_hook <<'EOF'
hook_bootstrap ctx
jq() { return 7; }
hook_context "remember to sync"
EOF
    _run "anything"
    assert_success
}
