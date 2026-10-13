#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

@test "acceptance section 5 opening backup count and list match CFGBK_NAMES (#527)" {
    # shellcheck source=script/verify/config_backup_paths.sh
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    local paragraph count list name label
    local -a numerals=(零 一 二 三 四 五 六 七 八 九 十) documented=() expected=()
    paragraph="$(sed -n '/^- \[ \] 5\. 實機/p' "${REPO_ROOT}/doc/acceptance.md")"
    [[ -n "${paragraph}" ]]
    count="${paragraph#*5.2 在建盒前備份 setup 可能寫入的}"
    count="${count%%個檔*}"
    assert_equal "${count}" "${numerals[${#CFGBK_NAMES[@]}]}"

    list="${paragraph#*個檔：}"
    list="${list%%（PR*}"
    list="${list//、/$'\n'}"
    mapfile -t documented <<<"${list}"
    for name in "${CFGBK_NAMES[@]}"; do
        case "${name}" in
            ghostty) label='Ghostty legacy config' ;;
            ghostty-modern) label='config.ghostty' ;;
            worktool) label='worktool 狀態檔' ;;
            distrobox-conf) label='distrobox.conf' ;;
            init-log) label='初始化 log（init-log）' ;;
            *) fail "undocumented backup name: ${name}" ;;
        esac
        expected+=("${label}")
    done
    assert_equal "${#documented[@]}" "${#CFGBK_NAMES[@]}"
    assert_equal "$(printf '%s\n' "${documented[@]}")" "$(printf '%s\n' "${expected[@]}")"
}

@test "acceptance 5.1 and 5.2 require confirmed ownership and preserve interrupt cleanup (#541)" {
    local doc
    doc="$(cat "${REPO_ROOT}/doc/acceptance.md")"
    [[ "${doc}" != *"所有權標記在 \`just box assemble\` **之前**就寫下"* ]]
    [[ "${doc}" != *'所有權記錄先於 assemble'* ]]
    [[ "${doc}" != *'本輪未啟動 assemble'* ]]
    [[ "${doc}" == *'assemble 前確認盒子不存在'* ]]
    [[ "${doc}" == *'中斷後 assemble 回非零'* ]]
    [[ "${doc}" == *"缺少 \`created-box\` 代表本輪未確認盒子所有權"* ]]
}
