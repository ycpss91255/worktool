#!/usr/bin/env bash
# Block a substantial non-CJK final reply so Claude rewrites it in zh-TW.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
hook_bootstrap "enforce_reply_language"

# Policy constants: 20 readable characters exempts terse acknowledgements;
# 30 percent permits ordinary English technical terms inside a zh-TW reply.
MIN_READABLE_LENGTH=20
MIN_CJK_PERCENT=30

_reply_counts() {
    jq -nr --arg text "$1" '
        def prose:
            gsub("(?s)```.*?```"; " ")
            | gsub("`[^`\\n]*`"; " ")
            | gsub("https?://[^[:space:]<>()\\[\\]]+"; " ")
            | gsub("(?m)(~?/|\\.{1,2}/|[[:alnum:]_.-]+/)[^[:space:]`<>()\\[\\]]+"; " ");
        def chars: [splits("") | select(test("[[:alnum:]]"))];
        ($text | prose | chars) as $readable
        | [$readable[] | select(test("[㐀-䶿一-鿿豈-﫿ぁ-ヿ가-힯]"))] as $cjk
        | "\($readable | length) \($cjk | length)"'
}

hook_read_input
[[ "$(hook_field '.stop_hook_active')" == "true" ]] && hook_allow
reply="$(hook_field '.last_assistant_message')"
read -r readable cjk <<<"$(_reply_counts "${reply}")"
[[ "${readable}" -lt "${MIN_READABLE_LENGTH}" ]] && hook_allow
[[ $((cjk * 100)) -ge $((readable * MIN_CJK_PERCENT)) ]] && hook_allow

jq -n '{
    decision: "block",
    reason: "請將最後回覆改寫為繁體中文（zh-TW），程式碼、指令與識別字維持原文。"
}'
