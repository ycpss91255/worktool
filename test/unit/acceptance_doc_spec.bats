#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

@test "acceptance PR 157 scope credits the signal and evidence fixes (#651)" {
    local paragraph entry
    paragraph="$(sed -n '/^本 PR(#157)/p' "${REPO_ROOT}/doc/acceptance.md")"
    entry="${paragraph#*逾時清理共用程式}"
    entry="${entry%%中斷矩陣共用程式*}"
    [[ "${entry}" == *'#647／PR #649'* ]]
    entry="${paragraph#*驗收程式與入口}"
    entry="${entry%%逾時清理共用程式*}"
    [[ "${entry}" == *'#648／PR #650'*"\`evidence.sh\`"* ]]
    entry="${paragraph#*\`test/unit/verify_*_spec.bats\`}"
    entry="${entry%%\`test/unit/test_sh_spec.bats\`*}"
    [[ "${entry}" == *"\`verify_run_signal_spec.bats\`"*'#647／PR #649'* ]]
    [[ "${entry}" == *"\`verify_evidence_spec.bats\`"*'#648／PR #650'* ]]
    entry="${paragraph#*\`doc/acceptance.md\`}"
    entry="${entry%%\`doc/evidence/README.md\`*}"
    [[ "${entry}" == *'#651'* ]]
}

@test "acceptance 2.1 documents exactly the runner CPU skip exemptions (#575)" {
    local policy section reason expected documented
    policy="$(sed -n '/^_has_unexpected_skip() {/,/^}/p' "${REPO_ROOT}/script/test/test.sh")"
    reason="$(sed -n 's/.*reason = " \(.*\)"/\1/p' <<<"${policy}")"
    expected="$(sed -n "s/.*\$0 == \"\([^\"]*\)\" reason.*/\1/p" <<<"${policy}" |
        while IFS= read -r name; do printf '%s | %s\n' "${name}" "${reason}"; done | sort)"
    [[ -n "${expected}" ]]
    section="$(sed -n '/^  - \[ \] 2\.1 裸/,/^  - \[ \] 2\.2 /p' "${REPO_ROOT}/doc/acceptance.md")"
    documented="$(sed -n "s/^      | \`\([^\`]*\)\` | \`\([^\`]*\)\` |$/\1 | \2/p" <<<"${section}" | sort)"
    assert_equal "${documented}" "${expected}"
    [[ "${section}" == *'除此之外，每層都不得有任何 skip'* ]]
    [[ "${section}" == *'WORKTOOL_STRESS=1 just test unit test/unit/verify_run_signal_spec.bats --filter'* ]]
    [[ "${section}" == *'WORKTOOL_STRESS=1 just test unit test/unit/verify_realbox_spec.bats --filter'* ]]
}

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

@test "acceptance 5.2 documents all managed parent chains and unique leftovers (#626)" {
    run grep -F "另以 \`absent-directories\` 記錄五個受管檔案各自原本不存在的完整上層目錄鏈" "${REPO_ROOT}/doc/acceptance.md"
    assert_success
    assert_output --partial 'missing/config/ghostty'
    assert_output --partial '第一個既有祖先'

    run grep -F '所有受管檔案還原後，五個受管檔案原本不存在的上層目錄鏈' "${REPO_ROOT}/doc/acceptance.md"
    assert_success
    assert_output --partial '反向排序'
    assert_output --partial "由最深層往上以 \`rmdir\` 移除"
    assert_output --partial '非空目錄保留，還原 fail closed'
    assert_output --partial '共用路徑只計一次'

    run grep -F "\`leftover-dirs=0\` 代表五個受管檔案原本不存在的完整上層目錄鏈均無殘留" "${REPO_ROOT}/doc/acceptance.md"
    assert_success
}

@test "acceptance 5.2 documents all managed parent chain ancestor mtime exceptions (#594)" {
    run grep -F '目錄 mtime（#526）' "${REPO_ROOT}/doc/acceptance.md"
    assert_success
    assert_output --partial '五個受管檔案的缺失父目錄鏈各自另記錄第一個既有祖先的 mtime'
    assert_output --partial '第一個既有祖先可能高於 config 或 cache 根目錄'
    assert_output --partial '例如 HOME'
    assert_output --partial 'XDG_CONFIG_HOME=/x/missing/config'
    assert_output --partial '記錄並還原 /x 的 mtime'
    assert_output --partial '#536'
    assert_output --partial '所有檔案、本輪新增設定目錄與五個受管檔案的缺失父目錄鏈處理完後才恢復既有目錄 mtime'
    assert_output --partial '已知限制：除上述五個受管檔案缺失父目錄鏈的第一個既有祖先外，設定根目錄以上的目錄 mtime 不受保護'
    refute_output --partial 'init-log 缺失目錄鏈'
}

@test "acceptance 5.2 documents actual relative cache parent handling (#594)" {
    run grep -F "非絕對路徑的 \`XDG_CACHE_HOME\` 不會單憑此條件拒絕備份" "${REPO_ROOT}/doc/acceptance.md"
    assert_success
    assert_output --partial "\`readlink -m\`"
    assert_output --partial "不會將 \`cfgbk_file_of\` 的 init-log 路徑改為絕對路徑"
}

@test "acceptance 5.2 documents dangling init-log target restoration (#594)" {
    run grep -F 'init-log 若是 dangling symlink' "${REPO_ROOT}/doc/acceptance.md"
    assert_success
    assert_output --partial "\`.tpath\`"
    assert_output --partial "空的 \`.tsha\`"
    assert_output --partial '刪除原本不存在、驗收期間才建立的目標檔'
    assert_output --partial '無法確定目標是否不存在時拒絕備份'
}
