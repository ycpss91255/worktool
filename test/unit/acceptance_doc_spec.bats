#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

@test "acceptance PR 157 scope credits interrupt, pairing and verbatim fixes (#659)" {
    local paragraph entry path credit
    paragraph="$(sed -n '/^本 PR(#157)/p' "${REPO_ROOT}/doc/acceptance.md")"
    while read -r path credit; do
        entry="${paragraph#*\`"${path}"\`（}"
        [[ "${entry}" != "${paragraph}" ]]
        entry="${entry%%）*}"
        [[ "${entry}" == *"${credit}"* ]]
    done <<'CREDITS'
lib/realbox_interrupt.sh #657／PR #661
doc/acceptance.md #659／PR #662
test/unit/acceptance_doc_spec.bats #659／PR #662
CREDITS
    entry="${paragraph#*驗收程式與入口}"
    entry="${entry%%逾時清理共用程式*}"
    [[ "${entry}" == *'#658／PR #660'*"\`evidence.sh\` 6.1"* ]]
    entry="${paragraph#*\`test/unit/verify_*_spec.bats\`}"
    entry="${entry%%\`test/unit/test_sh_spec.bats\`*}"
    [[ "${entry}" == *"\`verify_realbox_matrix_spec.bats\`"*'#657／PR #661'*'修正，'* ]]
    [[ "${entry}" == *"\`verify_evidence_spec.bats\`"*'#658／PR #660'*'修正'* ]]
    [[ "${entry}" == *"\`verify_setup_spec.bats\` 的 #659／PR #662"* ]]
}

@test "acceptance PR 157 scope credits the lint discovery fix on every touched entry (#655)" {
    local paragraph entry path
    paragraph="$(sed -n '/^本 PR(#157)/p' "${REPO_ROOT}/doc/acceptance.md")"
    for path in script/test/test.sh test/unit/test_sh_spec.bats \
        doc/acceptance.md test/unit/acceptance_doc_spec.bats; do
        entry="${paragraph#*\`"${path}"\`（}"
        [[ "${entry}" != "${paragraph}" ]]
        entry="${entry%%）*}"
        [[ "${entry}" == *'#655／PR #656'* ]]
    done
}

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
    [[ "${entry}" == *'#651／PR #652'* ]]
    [[ "${entry}" == *'#653／PR #654'* ]]
    entry="${paragraph#*\`test/unit/acceptance_doc_spec.bats\`}"
    entry="${entry%%\`test/unit/assemble_spec.bats\`*}"
    [[ "${entry}" == *'#651／PR #652'* ]]
    [[ "${entry}" == *'#653／PR #654'* ]]
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

_prepare_realbox_doc_stubs() {
    export FAKE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
    export HOME="${BATS_TEST_TMPDIR}/home" TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    export FAKE_WORKTOOL_LIB_DIR="${REPO_ROOT}/lib"
    unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME
    local bin="${BATS_TEST_TMPDIR}/bin" tool
    mkdir -p "${FAKE_STATE_DIR}" "${HOME}" "${TMPDIR}" "${bin}"
    touch "${FAKE_STATE_DIR}/boxes" "${FAKE_STATE_DIR}/calls.log" "${FAKE_STATE_DIR}/list-calls"
    for tool in distrobox gh jq; do
        install -m 0755 "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${bin}/${tool}"
    done
    export DOC_REAL_JUST
    DOC_REAL_JUST="$(command -v just)"
    export DOC_TOOL="${FAKE_STATE_DIR}/just"
    install -m 0755 "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${DOC_TOOL}"
    cat >"${bin}/just" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == verify ]]; then exec "${DOC_REAL_JUST}" "$@"; fi
# Match bench.sh's stream contract while keeping all container calls stubbed.
if [[ "${2:-}" == bench ]]; then
    printf '[INFO] shell median 176.9 ms within --max-ms 300\n' >&2
    export FAKE_JUST_BENCH_OUT=$'enter: min=136.1 median=171.1 max=197.0 ms\nshell: min=143.8 median=176.9 max=215.5 ms\ninbox: min=14.9 median=17.5 max=25.4 ms'
fi
exec bash "${DOC_TOOL}" "$@"
STUB
    chmod +x "${bin}/just"
    export PATH="${bin}:${PATH}"
}

_normalize_realbox_doc_output() {
    sed -E '/^\.\/script\//d;
        s/m3-51-[0-9]{8}T[0-9]{6}Z-[0-9]+/<run>/g;
        s/comment=[0-9]+/comment=<id>/g;
        s/(min=|median=|max=)[0-9]+([.][0-9]+)?/\1<n>/g;
        s/median [0-9]+([.][0-9]+)? ms/median <n> ms/g;
        s@/[^ ]+@<path>@g'
}

@test "acceptance 5.1 normal block matches both output streams bidirectionally (#666)" {
    _prepare_realbox_doc_stubs
    local section expected actual stream
    section="$(sed -n '/^  - \[ \] 5\.1 進盒/,/^  - \[ \] 5\.2 /p' "${REPO_ROOT}/doc/acceptance.md")"
    # Capture the current block too: the first RED must expose its omitted lines.
    expected="$(awk '/^      ````text$/ { block=1; next }
        /^      ````$/ && block { exit }
        block { sub(/^      /, ""); print }' <<<"${section}")"
    [[ -n "${expected}" ]]
    run --separate-stderr just verify realbox --allow-real-box 5.1
    assert_success
    actual="${output}"$'\nrc=0'
    printf '# stdout:\n%s\n# stderr:\n%s\n' "${actual}" "${stderr}" >&3
    assert_equal "$(printf '%s\n' "${actual}" | _normalize_realbox_doc_output)" \
        "$(printf '%s\n' "${expected}" | _normalize_realbox_doc_output)"
    for stream in stderr; do
        expected="$(awk -v stream="${stream}" '
            $0 == "      ````text " stream { block=1; next }
            /^      ````$/ && block { exit }
            block { sub(/^      /, ""); print }' <<<"${section}")"
        assert_equal "$(printf '%s\n' "${stderr}" | _normalize_realbox_doc_output)" \
            "$(printf '%s\n' "${expected}" | _normalize_realbox_doc_output)"
    done
}

@test "acceptance PR 157 credits the 5.1 output correction and preserves the box interface (#666)" {
    local paragraph entry path
    paragraph="$(sed -n '/^本 PR(#157)/p' "${REPO_ROOT}/doc/acceptance.md")"
    for path in doc/acceptance.md test/unit/acceptance_doc_spec.bats; do
        entry="${paragraph#*\`"${path}"\`（}"
        [[ "${entry}" != "${paragraph}" ]]
        entry="${entry%%）*}"
        [[ "${entry}" =~ \#666／PR[[:space:]](\#[0-9]+|待建立) ]]
    done
    [[ "${paragraph}" == *'`script/box/justfile.box`；#665／PR #673'* ]]
    [[ "${paragraph}" != *'665-review-round'* ]]
    run grep -F '(M3 adds enter / rm)' "${REPO_ROOT}/doc/acceptance.md"
    assert_failure 1
    run grep -F 'recipe 名稱與說明以根目錄 `justfile`、`script/box/justfile.box`、`script/test/justfile.test` 為唯一來源' "${REPO_ROOT}/doc/acceptance.md"
    assert_success
}
