#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/hook/transcript_reader_spec.bats
#
# Unit tests for `read_latest_user_message` in
# .agents/hook/enforce_shellcheck_disable_approval.sh.
#
# Module contract:
#   - Args: $1 = transcript_path
#   - Stdout: latest user-typed text message (most recent in file order)
#   - Exit: 0 always; missing/malformed content yields empty stdout
#
# Test fixtures are inline minimal JSONL written under BATS_TEST_TMPDIR.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    HOOK_SH="${HOOK_DIR}/enforce_shellcheck_disable_approval.sh"
    # shellcheck source=../../../.agents/hook/enforce_shellcheck_disable_approval.sh
    source "${HOOK_SH}"
    FIXTURE_DIR="${BATS_TEST_TMPDIR}/transcripts"
    mkdir -p "${FIXTURE_DIR}"
}

@test "read_latest_user_message: empty file -> empty stdout, exit 0" {
    local f="${FIXTURE_DIR}/empty.jsonl"
    : > "${f}"
    run read_latest_user_message "${f}"
    assert_success
    assert_output ""
}

@test "read_latest_user_message: missing file -> empty stdout, exit 0" {
    run read_latest_user_message "${FIXTURE_DIR}/does-not-exist.jsonl"
    assert_success
    assert_output ""
}

@test "read_latest_user_message: empty arg -> empty stdout, exit 0" {
    run read_latest_user_message ""
    assert_success
    assert_output ""
}

@test "read_latest_user_message: only assistant messages -> empty stdout" {
    local f="${FIXTURE_DIR}/asst-only.jsonl"
    cat > "${f}" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":"hello"}}
{"type":"assistant","message":{"role":"assistant","content":"world"}}
EOF
    run read_latest_user_message "${f}"
    assert_success
    assert_output ""
}

@test "read_latest_user_message: one user message (string content) returned" {
    local f="${FIXTURE_DIR}/one-user.jsonl"
    cat > "${f}" <<'EOF'
{"type":"user","message":{"role":"user","content":"approve SC2034"}}
EOF
    run read_latest_user_message "${f}"
    assert_success
    assert_output "approve SC2034"
}

@test "read_latest_user_message: alternating user/assistant - latest user wins" {
    local f="${FIXTURE_DIR}/alternating.jsonl"
    cat > "${f}" <<'EOF'
{"type":"user","message":{"role":"user","content":"first user msg"}}
{"type":"assistant","message":{"role":"assistant","content":"asst reply"}}
{"type":"user","message":{"role":"user","content":"approve SC2034"}}
{"type":"assistant","message":{"role":"assistant","content":"final reply"}}
EOF
    run read_latest_user_message "${f}"
    assert_success
    assert_output "approve SC2034"
}

@test "read_latest_user_message: array content with text block returned" {
    local f="${FIXTURE_DIR}/array-text.jsonl"
    cat > "${f}" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"approve SC1091"}]}}
EOF
    run read_latest_user_message "${f}"
    assert_success
    assert_output "approve SC1091"
}

@test "read_latest_user_message: tool_result-only array is skipped, falls back to prior text" {
    local f="${FIXTURE_DIR}/tool-result-then-text.jsonl"
    cat > "${f}" <<'EOF'
{"type":"user","message":{"role":"user","content":"approve SC2317"}}
{"type":"assistant","message":{"role":"assistant","content":"calling tool"}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"abc","content":"output"}]}}
EOF
    run read_latest_user_message "${f}"
    assert_success
    assert_output "approve SC2317"
}

@test "read_latest_user_message: malformed line skipped, valid prior line returned" {
    local f="${FIXTURE_DIR}/malformed.jsonl"
    cat > "${f}" <<'EOF'
{"type":"user","message":{"role":"user","content":"approve SC2155"}}
this is not json
EOF
    run read_latest_user_message "${f}"
    assert_success
    assert_output "approve SC2155"
}

@test "read_latest_user_message: a jq failure under the hook's own errexit skips the line (#218)" {
    # Sourcing the hook runs hook_bootstrap, so set -euo pipefail is live in
    # this shell and the call is made directly (not inside $(...), which
    # would drop -e): an unguarded jq failure would end the shell here.
    local f="${FIXTURE_DIR}/truncated-last.jsonl"
    cat > "${f}" <<'JSONL'
{"type":"user","message":{"role":"user","content":"approve SC2155"}}
{"type":"user","message":{"role":"user","content":
JSONL
    HOOK_SH="${HOOK_SH}" F="${f}" run bash -c \
        'source "${HOOK_SH}"; read_latest_user_message "${F}"; echo "still running"'
    assert_success
    assert_line --index 0 "approve SC2155"
    assert_line --index 1 "still running"
}
