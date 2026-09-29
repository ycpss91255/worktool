#!/usr/bin/env bats
# test/unit/hook/enforce_shellcheck_disable_approval_spec.bats
#   - .agents/hook/enforce_shellcheck_disable_approval.sh
#
# worktool keeps zero `# shellcheck disable` directives. This PreToolUse
# Edit|Write|MultiEdit hook DENIES (permissionDecision "deny", exit 0) an
# edit that introduces a new disable code unless the latest user-typed
# message in the session transcript says `approve SC<code>`. Driven as a
# subprocess (stdin JSON) the way Claude Code invokes it; the function-level
# contracts live in approval_check / disable_diff / transcript_reader specs.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    FIXTURE_DIR="${BATS_TEST_TMPDIR}/fixtures"
    mkdir -p "${FIXTURE_DIR}"
    # Synthetic transcript: one user message approving SC2034 only.
    TRANSCRIPT="${FIXTURE_DIR}/transcript.jsonl"
    cat >"${TRANSCRIPT}" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":"asking..."}}
{"type":"user","message":{"role":"user","content":"approve SC2034"}}
EOF
    TARGET_SH="${FIXTURE_DIR}/target.sh"
    printf '#!/usr/bin/env bash\nfoo=bar\n' >"${TARGET_SH}"
}

_check() { run_hook enforce_shellcheck_disable_approval "$1"; }

# _edit <file> <new_string> / _write <file> <content>
_edit() {
    jq -n --arg fp "$1" --arg ns "$2" --arg tp "${TRANSCRIPT}" \
        '{tool_name:"Edit", transcript_path:$tp, tool_input:{file_path:$fp, new_string:$ns}}'
}
_write() {
    jq -n --arg fp "$1" --arg c "$2" --arg tp "${TRANSCRIPT}" \
        '{tool_name:"Write", transcript_path:$tp, tool_input:{file_path:$fp, content:$c}}'
}

# _multiedit <file> <new_string>...
_multiedit() {
    local _fp="$1"
    shift
    jq -n --arg fp "${_fp}" --arg tp "${TRANSCRIPT}" '$ARGS.positional as $s
        | {tool_name:"MultiEdit", transcript_path:$tp,
           tool_input:{file_path:$fp, edits:[$s[] | {old_string:"x", new_string:.}]}}' \
        --args "$@"
}

_decision() { jq -r '.hookSpecificOutput.permissionDecision' <<<"${output}"; }

@test "Edit adding the approved SC2034 -> allow (empty stdout)" {
    _check "$(_edit "${TARGET_SH}" "$(disable_line SC2034)"$'\nfoo=baz')"
    assert_success
    assert_output ""
}

@test "a non-target tool (Bash) -> allow silently" {
    _check "$(hook_json "echo hi")"
    assert_success
    assert_output ""
}

@test "WORKTOOL_ALLOW_SHELLCHECK_DISABLE=1 bypass -> allow even without approval" {
    WORKTOOL_ALLOW_SHELLCHECK_DISABLE=1 _check "$(_edit "${TARGET_SH}" "$(disable_line SC1091)"$'\nsource x.sh')"
    assert_success
    assert_output ""
}

@test "Edit with no new disable -> allow silently" {
    _check "$(_edit "${TARGET_SH}" $'foo=baz\n# no disables here')"
    assert_success
    assert_output ""
}

@test "Edit adding unapproved SC1091 -> deny naming SC1091 and its wiki page" {
    _check "$(_edit "${TARGET_SH}" "$(disable_line SC1091)"$'\nsource x.sh')"
    assert_success
    assert_output --partial "SC1091"
    assert_output --partial "https://www.shellcheck.net/wiki/SC1091"
    run _decision
    assert_output "deny"
}

@test "the deny reason states worktool's zero-disable policy and the approval phrase" {
    _check "$(_edit "${TARGET_SH}" "$(disable_line SC1091)"$'\nsource x.sh')"
    assert_output --partial "zero"
    assert_output --partial "approve SC<code>"
    assert_output --partial "WORKTOOL_ALLOW_SHELLCHECK_DISABLE"
    refute_output --partial "issue #17"
    refute_output --partial "ECC_ALLOW"
}

@test "Write of a new file adding unapproved SC2317 -> deny" {
    _check "$(_write "${FIXTURE_DIR}/brand-new.sh" $'#!/usr/bin/env bash\n'"$(disable_line SC2317)"$'\nfoo() { :; }')"
    assert_output --partial "SC2317"
    run _decision
    assert_output "deny"
}

@test "MultiEdit where one edit adds unapproved SC1091 -> deny" {
    _check "$(_multiedit "${TARGET_SH}" 'foo=baz' "$(disable_line SC1091)"$'\nsource x.sh')"
    assert_output --partial "SC1091"
    run _decision
    assert_output "deny"
}

@test "deny lists the unapproved codes only (approved SC2034 absent)" {
    _check "$(_edit "${TARGET_SH}" "$(printf '%s\n%s\n%s\nfoo=baz' "$(disable_line SC2034)" "$(disable_line SC1091)" "$(disable_line SC2317)")")"
    assert_output --partial "SC1091"
    assert_output --partial "SC2317"
    refute_output --partial "https://www.shellcheck.net/wiki/SC2034"
}

@test "re-saving a file that already has SC1091 -> allow" {
    local _pre="${FIXTURE_DIR}/already.sh"
    printf '#!/usr/bin/env bash\n%s\nsource x.sh\n' "$(disable_line SC1091)" >"${_pre}"
    _check "$(_edit "${_pre}" "$(cat "${_pre}")")"
    assert_success
    assert_output ""
}
