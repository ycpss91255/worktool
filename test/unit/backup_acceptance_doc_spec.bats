#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    bats_require_minimum_version 1.5.0
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
}

_backup_doc_valid() {
    local doc="$1" paragraph count list name label
    local -a numerals=(零 一 二 三 四 五 六 七 八 九 十) documented=() expected=()
    paragraph="$(sed -n '/^- \[ \] 5\. 實機/p' "${doc}")"
    [[ -n "${paragraph}" ]] || return 1
    count="${paragraph#*5.2 在建盒前備份 setup 可能寫入的}"
    count="${count%%個檔*}"
    [[ "${count}" == "${numerals[${#CFGBK_NAMES[@]}]}" ]] || return 1
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
            *) return 1 ;;
        esac
        expected+=("${label}")
    done
    [[ "$(printf '%s\n' "${documented[@]}")" == "$(printf '%s\n' "${expected[@]}")" ]] || return 1
    [[ "$(printf '%s\n' "${CFGBK_PARENT_CHAIN_NAMES[@]}")" == "$(printf '%s\n' "${CFGBK_NAMES[@]}")" ]] || return 1
    local content
    content="$(cat "${doc}")"
    local required
    for required in \
        "另以 \`absent-directories\` 記錄五個受管檔案各自原本不存在的完整上層目錄鏈" \
        '共用路徑只計一次' '非空目錄保留，還原 fail closed' \
        '五個受管檔案的缺失父目錄鏈各自另記錄第一個既有祖先的 mtime' \
        '第一個既有祖先可能高於 config 或 cache 根目錄' \
        'init-log 若是 dangling symlink' "空的 \`.tsha\`" \
        '刪除原本不存在、驗收期間才建立的目標檔' \
        '還原前驗證這些資料並使用同一組已驗證的原目標' \
        '缺少足以驗證原目標的舊版備份拒絕自動還原' \
        '套用前的 live 一致性檢查仍使用當前環境與工作目錄' \
        '先檢查 live 設定仍與備份一致，並驗證完整備份可還原'; do
        [[ "${content}" == *"${required}"* ]] || return 1
    done
    [[ "${content}" != *'檔案操作仍依呼叫時的環境與工作目錄解析'* ]]
}

@test "backup acceptance documentation follows the current backup contract" {
    run _backup_doc_valid "${REPO_ROOT}/doc/acceptance.md"
    assert_success
}

@test "backup documentation guard rejects missing and obsolete claims" {
    local original="${REPO_ROOT}/doc/acceptance.md" copy="${BATS_TEST_TMPDIR}/acceptance.md" phrase
    for phrase in '初始化 log（init-log）' '共用路徑只計一次' "空的 \`.tsha\`" '還原前驗證這些資料並使用同一組已驗證的原目標'; do
        sed "s/${phrase}/removed/" "${original}" >"${copy}"
        run _backup_doc_valid "${copy}"
        assert_failure
    done
    cp "${original}" "${copy}"
    printf '%s\n' '檔案操作仍依呼叫時的環境與工作目錄解析' >>"${copy}"
    run _backup_doc_valid "${copy}"
    assert_failure
}
