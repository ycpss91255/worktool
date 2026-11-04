#!/usr/bin/env bats
# Documentation examples must follow their stated Ghostty config premise.

load "${BATS_TEST_DIRNAME}/../helper/common"

@test "enter docs: example logs consistently use the existing config.ghostty" {
    local _examples
    _examples="$(sed -n "/^### 範例 log/,/^\`home:\`/p" "${REPO_ROOT}/doc/enter.md")"
    run printf '%s\n' "${_examples}"
    assert_output --partial 'config.ghostty` 已存在'
    assert_output --partial '/home/me/.config/ghostty/config.ghostty'
    run grep -En '/home/me/\.config/ghostty/config([^.]|$)' <<<"${_examples}"
    assert_failure 1
}

@test "enter docs: example logs explicitly disclose omitted setup diagnostics" {
    local _intro
    _intro="$(sed -n '/^### 範例 log/,/^預設（/p' "${REPO_ROOT}/doc/enter.md")"
    run printf '%s\n' "${_intro}"
    assert_output --partial '以下 log 均為節錄'
    assert_output --partial 'distrobox.conf'
    assert_output --partial "\`wrote:\`／\`unchanged:\`"
    assert_output --partial "\`ghostty config:\`"
    assert_output --partial 'Ghostty reload 提示'
}
