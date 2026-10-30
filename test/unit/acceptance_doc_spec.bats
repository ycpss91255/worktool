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
    [[ -n "${expected}" ]] || return 1
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
if [[ "${2:-}" == bench ]]; then
    exec bash "${DOC_BENCH}" "${@:3}"
fi
exec bash "${DOC_TOOL}" "$@"
STUB
    chmod +x "${bin}/just"
    export PATH="${bin}:${PATH}"
    _prepare_doc_bench_commands "${bin}"
}

# Stub only external commands; setup, enter, bench and log_info remain real.
_prepare_doc_bench_commands() {
    local bin="$1"
    export DOC_BENCH="${REPO_ROOT}/script/box/bench.sh"
    mkdir -p "${FAKE_STATE_DIR}/external"
    export DOC_DISTROBOX="${FAKE_STATE_DIR}/external/distrobox"
    install -m 0755 "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${DOC_DISTROBOX}"
    export BENCH_PSI_FILE="${FAKE_STATE_DIR}/psi"
    export BENCH_BOX_PSI_FILE="${BENCH_PSI_FILE}"
    export BENCH_CLOCK="${bin}/bench-clock"
    printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' >"${BENCH_PSI_FILE}"
    printf '1000000\n' >"${FAKE_STATE_DIR}/clock"
    cat >"${bin}/bench-clock" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cat "${FAKE_STATE_DIR}/clock"
STUB
    cat >"${bin}/sleep" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
exit 0
STUB
    cat >"${bin}/distrobox" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == enter ]]; then
    read -r now <"${FAKE_STATE_DIR}/clock"
    printf '%s\n' "$((now + 10000))" >"${FAKE_STATE_DIR}/clock"
    if [[ "$*" == *bench-inbox* ]]; then printf '1000\n'; fi
    exit 0
fi
exec bash "${DOC_DISTROBOX}" "$@"
STUB
    chmod +x "${bin}/bench-clock" "${bin}/sleep" "${bin}/distrobox"
}

_normalize_realbox_doc_output() {
    sed -E '/^\.\/script\//d;
        s/m3-51-[0-9]{8}T[0-9]{6}Z-[0-9]+/<run>/g;
        s/comment=[0-9]+/comment=<id>/g;
        s/^(host-state baseline: present=)[0-9]+/\1<n>/;
        s/^(box-state before-cleanup: home=)[01]( tmux=)[01]$/\1<n>\2<n>/;
        s/(min=|median=|max=)[0-9]+([.][0-9]+)?/\1<n>/g;
        s/median [0-9]+([.][0-9]+)? ms/median <n> ms/g;
        s@/[^ ]+@<path>@g'
}

_normalize_realbox_doc_stderr() {
    # Only omit the optional setup/PSI/progress diagnostics named in section 5.1.
    # Apply this to stderr alone so a diagnostic moved to stdout still fails.
    sed -E '/^\[INFO\] (auto-enter:|terminal:|box:|ghostty config:|distrobox:|wrote:|Ghostty config changed:)/d;
        /^\[INFO\] (box psi wait |psi (before|after) |host (quiet|stayed quiet):)/d;
        /^\[INFO\] (enter|shell|inbox): [0-9]+ warmup \+ [0-9]+ run\(s\) of /d' |
        _normalize_realbox_doc_output
}

_assert_realbox_doc_streams() {
    local section expected actual output="" stderr=""
    section="$(sed -n '/^  - \[ \] 5\.1 進盒/,/^  - \[ \] 5\.2 /p' "$1")"
    # Compare complete streams after normalizing environment-dependent fields.
    expected="$(awk '/^      ````text$/ { block=1; next }
        /^      ````$/ && block { exit }
        block { sub(/^      /, ""); print }' <<<"${section}")"
    [[ -n "${expected}" ]] || return 1
    [[ "${expected}" == *"box-state before-cleanup: home=1 tmux=1"* ]] || return 1
    run --separate-stderr just verify realbox --allow-real-box 5.1
    if ! assert_success; then printf '%s\n' "${stderr}"; return 1; fi
    actual="${output}"$'\nrc=0'
    assert_equal "$(printf '%s\n' "${actual}" | _normalize_realbox_doc_output)" \
        "$(printf '%s\n' "${expected}" | _normalize_realbox_doc_output)" || return 1
    expected="$(awk '
        /^      ````text stderr$/ { block=1; next }
        /^      ````$/ && block { exit }
        block { sub(/^      /, ""); print }' <<<"${section}")"
    assert_equal "$(printf '%s\n' "${stderr}" | _normalize_realbox_doc_stderr)" \
        "$(printf '%s\n' "${expected}" | _normalize_realbox_doc_stderr)"
}

@test "acceptance 5.1 normal block matches both output streams bidirectionally (#666)" {
    _prepare_realbox_doc_stubs
    _assert_realbox_doc_streams "${REPO_ROOT}/doc/acceptance.md"
}

@test "acceptance 5.1 comparison rejects stub cleanup state in the real host block (#666)" {
    _prepare_realbox_doc_stubs
    local doc="${BATS_TEST_TMPDIR}/acceptance.md"
    sed 's/box-state before-cleanup: home=1 tmux=1/box-state before-cleanup: home=0 tmux=0/' \
        "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_realbox_doc_streams "${doc}"
    assert_failure
}

@test "acceptance 5.1 successful comparison emits no fd 3 dump (#666)" {
    _prepare_realbox_doc_stubs
    local dump="${BATS_TEST_TMPDIR}/diagnostics"
    run _assert_realbox_doc_streams "${REPO_ROOT}/doc/acceptance.md" 3>"${dump}"
    assert_success
    [[ ! -s "${dump}" ]]
}

@test "acceptance 5.1 comparison rejects a real bench summary moved to stdout (#666)" {
    _prepare_realbox_doc_stubs
    local mutant="${BATS_TEST_TMPDIR}/mutant"
    mkdir -p "${mutant}"
    cp -a "${REPO_ROOT}/script" "${REPO_ROOT}/lib" "${mutant}/"
    export DOC_BENCH="${mutant}/script/box/bench.sh"
    sed -i 's/log_info "shell median \(.*within --max-ms.*\)"/echo "[INFO] shell median \1"/' "${DOC_BENCH}"
    run _assert_realbox_doc_streams "${REPO_ROOT}/doc/acceptance.md"
    assert_failure
    assert_output --partial '-- values do not equal --'
    assert_output --partial '[INFO] shell median'
}

_assert_51_credits() {
    local paragraph entry path
    paragraph="$(sed -n '/^本 PR(#157)/p' "$1")"
    for path in doc/acceptance.md test/unit/acceptance_doc_spec.bats; do
        entry="${paragraph#*\`"${path}"\`（}"
        [[ "${entry}" != "${paragraph}" ]] || return 1
        entry="${entry%%）*}"
        [[ "${entry}" =~ \#666／PR[[:space:]]\#682([^0-9]|$) ]] || return 1
    done
    [[ "${paragraph}" == *"\`script/box/justfile.box\`；#665／PR #673"* ]] || return 1
    [[ "${paragraph}" != *'665-review-round'* ]] || return 1
    run grep -F '(M3 adds enter / rm)' "${REPO_ROOT}/doc/acceptance.md"
    assert_failure 1 || return 1
    run grep -F "recipe 名稱與說明以根目錄 \`justfile\`、\`script/box/justfile.box\`、\`script/test/justfile.test\` 為唯一來源" "${REPO_ROOT}/doc/acceptance.md"
    assert_success
}

@test "acceptance PR 157 credits the 5.1 output correction and preserves the box interface (#666)" {
    _assert_51_credits "${REPO_ROOT}/doc/acceptance.md"
}

@test "acceptance 5.1 credits reject missing box interface credit (#666)" {
    local doc="${BATS_TEST_TMPDIR}/acceptance.md"
    sed "s@\`script/box/justfile.box\`；#665／PR #673@\`script/box/justfile.box\`；missing@" \
        "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_51_credits "${doc}"
    assert_failure
}

@test "acceptance 5.1 credits reject a different PR or a longer PR number (#666)" {
    local wrong doc="${BATS_TEST_TMPDIR}/acceptance.md"
    for wrong in 681 6820; do
        sed "s/#666／PR #682/#666／PR #${wrong}/g" "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
        run _assert_51_credits "${doc}"
        assert_failure
    done
}

@test "acceptance PR 157 credits the stale rm description fix on every touched entry (#666)" {
    local paragraph entry path
    paragraph="$(sed -n '/^本 PR(#157)/p' "${REPO_ROOT}/doc/acceptance.md")"
    for path in justfile doc/structure.md doc/design.md doc/acceptance.md \
        test/unit/justfile_spec.bats; do
        entry="${paragraph#*\`"${path}"\`（}"
        [[ "${entry}" != "${paragraph}" ]]
        entry="${entry%%）*}"
        [[ "${entry}" == *'#665／PR #673'* ]]
    done
    [[ "${paragraph}" == *"\`script/box/justfile.box\`；#665／PR #673"* ]]
}

@test "acceptance 5.2 documents automation and credits every #663 file" {
    local paragraph section entry
    paragraph="$(sed -n '/^本 PR(#157)/p' "${REPO_ROOT}/doc/acceptance.md")"
    for entry in 'realbox.sh' 'verify_realbox_spec.bats' 'doc/acceptance.md' 'test/unit/acceptance_doc_spec.bats'; do
        [[ "${paragraph}" == *"\`${entry}\`（#663／PR #668"* ]]
    done
    section="$(sed -n '/^  - \[ \] 5\.2 開終端/,/^  - \[ \] 5\.3 先建/p' "${REPO_ROOT}/doc/acceptance.md")"
    [[ "${section}" == *'Ghostty 1.3.1'*'reload-config'* ]]
    [[ "${section}" == *'ghostty +new-window'* ]]
    [[ "${section}" == *'主觀項目，不影響 rc'* ]]
    [[ "${section}" != *'輸入 PID'* ]]
    [[ "${section}" != *"echo \$fish_pid"* ]]
    [[ "${section}" != *'需互動 tty'* ]]
}

load "${BATS_TEST_DIRNAME}/../helper/realbox_window"

_prepare_52_doc_tools() {
    _prepare_realbox_tools
    _auto_window_tools
    cp "${STUBS}/just" "${STATE}/just"
    export DOC_ENTER="${REPO_ROOT}/script/box/enter.sh"
    cat >"${STUBS}/just" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${2:-}" == enter ]]; then exec "${DOC_ENTER}" "${@:3}"; fi
exec "${FAKE_STATE_DIR}/just" "$@"
STUB
    cp "${STUBS}/docker" "${STATE}/docker"
    cat >"${STUBS}/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    inspect) printf '0001-01-01T00:00:00Z\n' ;;
    start) mkdir -p "${XDG_CACHE_HOME%/cache}/box-home/.cache/tmux" ;;
    logs) printf 'container_setup_done\n' ;;
    *) exec "${FAKE_STATE_DIR}/docker" "$@" ;;
esac
STUB
}

_52_doc_stream() {
    awk -v stream="$2" '
        /^  - \[ \] 5\.2 開終端/ {section=1}
        /^  - \[ \] 5\.3 / {section=0}
        section && $0 == "      ````text " stream {block=1; next}
        block && /^      ````$/ {exit}
        block {sub(/^      /, ""); print}' "$1"
}

_normalize_52_doc() {
    sed -E 's@[a-f0-9]{64}@<sha>@g;
        s@/tmp/[^ ]+@<path>@g;
        s/after [0-9]+s/after <elapsed>/g;
        s/pid=[0-9]+/pid=<pid>/g;
        s/mnt:\[[0-9]+\]/mnt:[<ns>]/g'
}

_assert_52_doc() {
    local output="" stderr=""
    run --separate-stderr "${REALBOX}" --allow-real-box 5.2 </dev/null
    if ! assert_success; then printf '%s\n' "${stderr}"; return 1; fi
    DOC_52_OUTPUT="${output}" DOC_52_STDERR="${stderr}"
    _compare_52_doc "$1" "${output}" "${stderr}"
}

_compare_52_doc() {
    local expected section output="$2" stderr="$3"
    section="$(sed -n '/^  - \[ \] 5\.2 開終端/,/^  - \[ \] 5\.3 /p' "$1")"
    [[ "${section}" == *'box-state before-cleanup: home=1 tmux=1'* ]] || return 1
    expected="$(_52_doc_stream "$1" stdout)"
    assert_equal "$(printf '%s\n' "${output}" | _normalize_52_doc)" \
        "$(printf '%s\n' "${expected}" | _normalize_52_doc)" || return 1
    expected="$(_52_doc_stream "$1" stderr)"
    assert_equal "$(printf '%s\n' "${stderr}" | _normalize_52_doc)" \
        "$(printf '%s\n' "${expected}" | _normalize_52_doc)"
}

@test "#691: acceptance 5.2 compares first-start stdout and stderr bidirectionally" {
    _prepare_52_doc_tools
    local doc="${REPO_ROOT}/doc/acceptance.md" mutant="${BATS_TEST_TMPDIR}/mutant.md"
    _assert_52_doc "${doc}"
    sed '/^      phase=first-start$/d' "${doc}" >"${mutant}"
    run _compare_52_doc "${mutant}" "${DOC_52_OUTPUT}" "${DOC_52_STDERR}"
    assert_failure
    sed '/^      ````text stdout$/a\      unexpected=1' "${doc}" >"${mutant}"
    run _compare_52_doc "${mutant}" "${DOC_52_OUTPUT}" "${DOC_52_STDERR}"
    assert_failure
    sed 's/box-state before-cleanup: home=1 tmux=1/box-state before-cleanup: home=1 tmux=0/g' "${doc}" >"${mutant}"
    run _compare_52_doc "${mutant}" "${DOC_52_OUTPUT}" "${DOC_52_STDERR}"
    assert_failure
    run _compare_52_doc "${doc}" "${DOC_52_OUTPUT}"$'\nphase=first-start' "${DOC_52_STDERR}"
    assert_failure
}
