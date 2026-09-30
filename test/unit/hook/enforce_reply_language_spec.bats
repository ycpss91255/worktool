#!/usr/bin/env bats
# test/unit/hook/enforce_reply_language_spec.bats - Stop reply language gate.

load "${BATS_TEST_DIRNAME}/../../helper/common"
load "${BATS_TEST_DIRNAME}/../../helper/hook"

setup() {
    FIXTURE_DIR="${BATS_TEST_DIRNAME}/fixture/reply_language"
}

_payload() {
    sed "s|TRANSCRIPT_PATH|${FIXTURE_DIR}/transcript.jsonl|" \
        "${FIXTURE_DIR}/$1.json"
}

@test "blocks an all-English paragraph and asks for a zh-TW rewrite" {
    run_hook enforce_reply_language "$(_payload all_english)"
    assert_success
    run jq -r '.decision + "|" + .reason' <<<"${output}"
    assert_success
    assert_output --partial "block|"
    assert_output --partial "繁體中文"
    assert_output --partial "程式碼、指令與識別字維持原文"
}

@test "allows an all-Chinese reply" {
    run_hook enforce_reply_language "$(_payload all_chinese)"
    assert_success
    assert_output ""
}

@test "allows Chinese with English terms, commands, URLs, and file paths" {
    run_hook enforce_reply_language "$(_payload chinese_with_english)"
    assert_success
    assert_output ""
}

@test "allows a reply containing only a fenced code block" {
    run_hook enforce_reply_language "$(_payload code_block_only)"
    assert_success
    assert_output ""
}

@test "allows a very short English reply" {
    run_hook enforce_reply_language "$(_payload very_short)"
    assert_success
    assert_output ""
}

@test "allows one retry when a Stop hook is already active" {
    local payload
    payload="$(_payload all_english)"
    payload="$(jq '.stop_hook_active = true' <<<"${payload}")"
    run_hook enforce_reply_language "${payload}"
    assert_success
    assert_output ""
}
