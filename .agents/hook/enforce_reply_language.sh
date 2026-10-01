#!/usr/bin/env bash
# Block a substantial non-CJK final reply so Claude rewrites it in zh-TW.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
hook_bootstrap "enforce_reply_language"

# Policy constants: 20 readable units exempts terse acknowledgements, while
# 30 percent permits English technical terms inside a zh-TW reply. One CJK
# character or one consecutive ASCII alphanumeric word is one unit; punctuation
# such as the hyphen in system-real separates words.
MIN_READABLE_UNITS=20
MIN_CJK_PERCENT=30

_reply_counts() {
    jq -nr --arg text "$1" '
        def prose:
            gsub("(?s)```.*?```"; " ")
            | gsub("`[^`\\n]*`"; " ")
            | gsub("https?://[^[:space:]<>()\\[\\]]+"; " ")
            | gsub("(?m)(~?/|\\.{1,2}/|[[:alnum:]_.-]+/)[^[:space:]`<>()\\[\\]]+"; " ");
        def units: [scan("[㐀-䶿一-鿿豈-﫿ぁ-ヿ가-힯]|[A-Za-z0-9]+")];
        ($text | prose | units) as $readable
        | [$readable[] | select(test("[㐀-䶿一-鿿豈-﫿ぁ-ヿ가-힯]"))] as $cjk
        | "\($readable | length) \($cjk | length)"'
}

hook_read_input
[[ "$(hook_field '.stop_hook_active')" == "true" ]] && hook_allow
reply="$(hook_field '.last_assistant_message')"
read -r readable cjk <<<"$(_reply_counts "${reply}")"
[[ "${readable}" -lt "${MIN_READABLE_UNITS}" ]] && hook_allow
[[ $((cjk * 100)) -ge $((readable * MIN_CJK_PERCENT)) ]] && hook_allow

jq -n '{
    decision: "block",
    reason: "請將最後回覆改寫為繁體中文（zh-TW），程式碼、指令與識別字維持原文。"
}'
