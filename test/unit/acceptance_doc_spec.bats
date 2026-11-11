#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

@test "acceptance PR 157 scope leaves per-PR sources to the PR 157 description (#730)" {
    local paragraph numbers
    paragraph="$(sed -n '/^本 PR(#157)/p' "${REPO_ROOT}/doc/acceptance.md")"
    [[ -n "${paragraph}" ]] || return 1
    [[ "${paragraph}" == *'逐 PR 的來源見 PR #157 說明'* ]]
    # Any issue or PR number other than #157 itself is a per-PR source note.
    numbers="$(grep -oE '#[0-9]+' <<<"${paragraph}" | sort -u)"
    assert_equal "${numbers}" '#157'
}

@test "acceptance 2.1 documents exactly the runner CPU skip exemptions (#575)" {
    local policy section reason expected documented
    policy="$(sed -n '/^test_shard_has_unexpected_skip() {/,/^}/p' "${REPO_ROOT}/lib/test_shard.sh")"
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

@test "acceptance keeps the box interface wording (#666)" {
    run grep -F '(M3 adds enter / rm)' "${REPO_ROOT}/doc/acceptance.md"
    assert_failure 1
    run grep -F "recipe 名稱與說明以根目錄 \`justfile\`、\`script/box/justfile.box\`、\`script/test/justfile.test\` 為唯一來源" "${REPO_ROOT}/doc/acceptance.md"
    assert_success
}

@test "acceptance 5.2 documents automation (#663)" {
    local section
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
    export FAKE_JUST_BOX_SCRIPT_DIR="${REPO_ROOT}/script/box"
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
    inspect)
        # enter.sh asks State.Running while the log follower may still be
        # catching up; answer it as a running box, not the StartedAt value.
        if [[ "$*" == *'.State.Running'* ]]; then printf 'true\n'
        else printf '0001-01-01T00:00:00Z\n'; fi ;;
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
        s@/(tmp|source)/[^ ]+@<path>@g;
        s/after [0-9]+s/after <elapsed>/g;
        s/pid=[0-9]+/pid=<pid>/g;
        s/mnt:\[[0-9]+\]/mnt:[<ns>]/g'
}

_normalize_52_doc_stderr() {
    # Section 5.2 excerpts setup diagnostics, keeping the auto-enter source.
    sed -E '/^\[INFO\] (terminal:|box:|ghostty config:|distrobox:|wrote:|Ghostty config changed:)/d' |
        _normalize_52_doc
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
    assert_equal "$(printf '%s\n' "${stderr}" | _normalize_52_doc_stderr)" \
        "$(printf '%s\n' "${expected}" | _normalize_52_doc_stderr)"
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

@test "6.2: evidence documentation requires every cell to be exactly one" {
    local section
    section="$(sed -n '/^  - \[ \] 6\.2 /,/^  - \[ \] 6\.3 /p' "${REPO_ROOT}/doc/acceptance.md")"
    [[ "${section}" == *"預期看到資訊(每格為 \`1\`)"* ]]
    [[ "${section}" != *'每行數字 >= 1'* ]]
}

@test "6.3: evidence documentation lists every failure word" {
    local section word
    section="$(sed -n '/^  - \[ \] 6\.3 /,/^## M4 /p' "${REPO_ROOT}/doc/acceptance.md")"
    for word in blocked NOT gh-failed no-codex BAD \
        '#N no-follow-up' '#N no-fix-pr' '#N no-claude-comment' \
        '#N grep-failed' '#N bad-fix-pr'; do
        [[ "${section}" == *"\`${word}\`"* ]]
    done
}

@test "#713: setup user-content coverage includes every seeded path" {
    local paragraph section item
    paragraph="$(sed -n '/受管檔案是.*使用者的/p' "${REPO_ROOT}/doc/acceptance.md")"
    for item in 3.10 3.11 3.12 3.13; do
        [[ "${paragraph}" == *"${item}"* ]]
    done
    section="$(sed -n '/^  - \[ \] 3\.11 /,/^  - \[ \] 3\.12 /p' "${REPO_ROOT}/doc/acceptance.md")"
    [[ "${section}" == *"每次寫入、改寫與移除後都檢查 \`~/.tmux.conf\` 的使用者內容"* ]]
    [[ "${paragraph}" == *'檔尾空白行與最後換行'* ]]
}

@test "#714: acceptance 2.3 limits exact case counts to selected ok lines" {
    local section
    section="$(sed -n '/^  - \[ \] 2\.3 /,/^  - \[ \] 2\.4 /p' "${REPO_ROOT}/doc/acceptance.md")"
    [[ "${section}" == *"只適用於 pattern 選中的 \`ok\` 行（含 ghostty）"* ]]
    [[ "${section}" == *"其餘案例的失敗由 \`^not ok\` 與 tier rc 擋住"* ]]
}

@test "#714: acceptance 2.3 assigns namespace equality to bats and format checks to gate" {
    local section
    section="$(sed -n '/^  - \[ \] 2\.3 /,/^  - \[ \] 2\.4 /p' "${REPO_ROOT}/doc/acceptance.md")"
    [[ "${section}" == *'mntns 相等由 bats 案例保證'* ]]
    [[ "${section}" == *"\`gate.sh\` 只檢查 \`mntns=mnt:[數字]\` 格式與字面 \`== dev container\`"* ]]
    [[ "${section}" != *"\`mntns=\` 必須是盒子的 mount namespace"* ]]
}

@test "#724: structure documents exactly the runner unit CPU skip exemptions" {
    local policy section reason expected documented
    policy="$(sed -n '/^test_shard_has_unexpected_skip() {/,/^}/p' "${REPO_ROOT}/lib/test_shard.sh")"
    reason="$(sed -n 's/.*reason = " \(.*\)"/\1/p' <<<"${policy}")"
    expected="$(sed -n "s/.*\$0 == \"\([^\"]*\)\" reason.*/\1/p" <<<"${policy}" |
        while IFS= read -r name; do printf '%s | %s\n' "${name}" "${reason}"; done | sort)"
    [[ -n "${expected}" ]]
    section="$(sed -n '/^## 測試/,/^## CI/p' "${REPO_ROOT}/doc/structure.md")"
    documented="$(sed -n "s/^| \`\\([^\`]*\\)\` | \`\\([^\`]*\\)\` |\$/\\1 | \\2/p" <<<"${section}" | sort)"
    assert_equal "${documented}" "${expected}"
    [[ "${section}" == *"未設 \`WORKTOOL_STRESS=1\`（未設定或值不是 \`1\`）時，unit 層只允許以下三個 CPU 負載重現案例"* ]]
    [[ "${section}" == *'除此之外，每層都不得有任何 skip'* ]]
    [[ "${section}" == *"設 \`WORKTOOL_STRESS=1\` 時，這三個案例也不得 skip"* ]]
}

@test "#712: window deadlines distinguish scanning, evidence probes and session cleanup" {
    local doc
    doc="$(cat "${REPO_ROOT}/doc/acceptance.md")"
    [[ "${doc}" == *'快照與所有權掃描的 10 秒搜尋預算'* ]]
    [[ "${doc}" == *'TIMEOUT_SHORT=180 秒，TERM 後最多再等 10 秒才 KILL'* ]]
    [[ "${doc}" == *'收尾掃描與升級的等待上限為 15 秒'* ]]
    [[ "${doc}" == *'整數 SECONDS 的開始值加 9 為掃描期限'* ]]
    [[ "${doc}" == *'開始值加 4，第 3 秒起不再開始重試（開始值加 3）'* ]]
    [[ "${doc}" == *"\`guard_timed 1 ps\` 或 \`guard_timed 1 kill\`"* ]]
    [[ "${doc}" == *'root 消失後另查 PGID／SID 的 session 探測'* ]]
    [[ "${doc}" == *"輪間另有 \`sleep 0.1\`"* ]]
    [[ "${doc}" == *'namespace 的本機 readlink 沒有獨立 timeout'* ]]
    [[ "${doc}" == *'還原祖先鏈最多 64 次 ps 也各自計時'* ]]
    [[ "${doc}" == *'套用模式的例外：到期時若先前已記錄非 fish 候選'* ]]
    [[ "${doc}" == *'追蹤到的 root PID 消失後（含首次收尾快照已缺少已確認 root 的情況），同樣確認 session 的 PGID／SID 已無存活成員後才移除目錄'* ]]
    [[ "${doc}" == *'成員仍存活或 session 檢查無法判定時，保留目錄並回非零'* ]]
    [[ "${doc}" != *'最後一次外部探測最多 1 秒，因此總上限為 5 秒'* ]]
}

# The `<tool>\t<item>` lines the tool list (stdin) states: every
# `` `<tool>`(<note>,|;<items> 用) `` with its items split on ` / ` and each
# range `a.b-a.c` expanded.
_doc_tool_items() {
    local _ann _tool _items _item _first _last _prefix _n _nl=$'\n'
    while IFS= read -r _ann; do
        _tool="${_ann#\`}"
        _tool="${_tool%%\`*}"
        _items="${_ann#*\(}"
        _items="${_items% 用)}"
        _items="${_items##*[,;]}"
        while IFS= read -r _item; do
            if [[ "${_item}" == *-* ]]; then
                _first="${_item%-*}"
                _last="${_item#*-}"
                _prefix="${_first%.*}"
                [[ "${_last%.*}" == "${_prefix}" ]] || return 1
                for (( _n = ${_first##*.}; _n <= ${_last##*.}; _n++ )); do
                    printf '%s\t%s.%s\n' "${_tool}" "${_prefix}" "${_n}"
                done
            else
                printf '%s\t%s\n' "${_tool}" "${_item}"
            fi
        done <<<"${_items// \/ /${_nl}}"
    done < <(grep -oE "\`[a-z][a-z0-9_-]*\`\([^)]* 用\)")
}

# Tools the list covers without naming items: the repo's own dependencies,
# the distrobox / ghostty sentence, the shells, `awk` / `grep` / `sed` and
# the coreutils catch-all.
ACCEPTANCE_UNANNOTATED_TOOLS=(docker just git bash sh distrobox ghostty awk grep sed
    cat chmod cp cut date dirname env id ln mkdir mkfifo mktemp mv readlink realpath
    rm rmdir sha256sum sleep sort stat tee timeout touch uname wc)

@test "acceptance tool list names exactly the items each tool is required by (#718, #771)" {
    load "${BATS_TEST_DIRNAME}/../helper/graph"
    load "${BATS_TEST_DIRNAME}/../helper/verify_tools"
    local tools rule list derived expected documented
    local -a scripts
    tools="$(sed -n '/^- 驗收工具:/p' "${REPO_ROOT}/doc/acceptance.md")"
    [[ -n "${tools}" ]] || return 1
    # The item scripts, as the document names them.
    list="$(grep -oE "\`script/verify/\`\((\`[a-z_]+\.sh\`( / )?)+\)" "${REPO_ROOT}/doc/acceptance.md" |
        grep -oE '[a-z_]+\.sh' | sed 's|^|script/verify/|')"
    mapfile -t scripts <<<"${list}"
    [[ "${#scripts[@]}" -eq 6 ]] || return 1
    derived="$(verify_item_tools "${REPO_ROOT}" "${scripts[@]}")"
    [[ -n "${derived}" ]] || return 1
    expected="$(awk -F'\t' 'NR == FNR { skip[$1] = 1; next } !($1 in skip)' \
        <(printf '%s\n' "${ACCEPTANCE_UNANNOTATED_TOOLS[@]}") - <<<"${derived}")"
    [[ -n "${expected}" ]] || return 1
    documented="$(_doc_tool_items <<<"${tools}" | LC_ALL=C sort -u)"
    assert_equal "${documented}" "${expected}"
    [[ "${tools}" == *"\`awk\` / \`grep\` / \`sed\`"* ]]
    [[ "${tools}" == *'coreutils 指令'* ]]
    # "1-2、4、6 不需 distrobox / ghostty": only sections 3 and 5 require them.
    [[ "${tools}" == *'1-2、4、6 不需 distrobox / ghostty'* ]]
    run awk -F'\t' '($1 == "distrobox" || $1 == "ghostty") && $2 !~ /^[35]\./' <<<"${derived}"
    assert_output ''
    [[ "${tools}" != *'(coreutils + awk)'* ]]
    rule="$(sed -n "/^規則:入口一律 \`just\`/p" "${REPO_ROOT}/doc/acceptance.md")"
    [[ -n "${rule}" ]] || return 1
    [[ "${rule}" == *'驗收工具(timeout / gh / jq / grep)查'* ]]
}

@test "the tool derivation follows an item's call closure and fails closed (#771)" {
    load "${BATS_TEST_DIRNAME}/../helper/graph"
    load "${BATS_TEST_DIRNAME}/../helper/verify_tools"
    local tree="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${tree}/script/verify"
    cat >"${tree}/script/verify/x.sh" <<'EOF'
_dispatch() {
    case "$1" in
        9.1) _item_9_1 ;;
        9.2) printf 'grp\n' ;;
    esac
}
_helper() {
    guard_require zstd \
        xz || return $?
}
_item_9_1() { _helper; for _t in lz4 lzop; do _p="$(_resolve_exec "${_t}" 'why')"; done; _cleanup_push 9-a; }
_cleanup_run() {
    case "$1" in
        9-a) _clean_a ;;
        9-b) _clean_b ;;
    esac
}
_clean_a() { guard_require unzip; }
_clean_b() { guard_require rar; }
_preconditions_grp() { _require_tool brotli "$1"; type -P pigz >/dev/null; }
_unreached() { guard_require bzip2; }
EOF
    run verify_item_tools "${tree}" script/verify/x.sh
    assert_success
    assert_output "$(printf '%s\t%s\n' brotli 9.2 lz4 9.1 lzop 9.1 pigz 9.2 unzip 9.1 xz 9.1 zstd 9.1)"
    printf '%s\n' '_f() { guard_require zstd; }' >"${tree}/script/verify/x.sh"
    run verify_item_tools "${tree}" script/verify/x.sh
    assert_failure
    assert_output --partial 'no item entry point found in script/verify/x.sh'
}

@test "the tool derivation follows a child run of another item of the same script (#782)" {
    load "${BATS_TEST_DIRNAME}/../helper/graph"
    load "${BATS_TEST_DIRNAME}/../helper/verify_tools"
    local tree="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${tree}/script/verify"
    cat >"${tree}/script/verify/x.sh" <<'EOF'
_dispatch() {
    case "$1" in
        9.1) _item_9_1 ;;
        9.2) _item_9_2 ;;
        9.3) _item_9_3 ;;
    esac
}
_item_9_1() { guard_require zstd; }
_item_9_2() {
    guard_require xz || return $?
    setsid bash "${SCRIPT_DIR}/x.sh" --allow "${REPO}" \
        --box "${BOX}" 9.1 >>"${capture}" 2>&1 &
}
_item_9_3() { bash "${SCRIPT_DIR}/other.sh" 9.1 >/dev/null; guard_require lz4; }
EOF
    run verify_item_tools "${tree}" script/verify/x.sh
    assert_success
    assert_output "$(printf '%s\t%s\n' lz4 9.3 xz 9.2 zstd 9.1 zstd 9.2)"
}
