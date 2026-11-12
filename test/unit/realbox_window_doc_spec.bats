#!/usr/bin/env bats
# Guard the 5.2 window contract independently of the executable behavior.
load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    DOC="${REPO_ROOT}/doc/acceptance.md"
}

_window_contract() {
    local section
    section="$(awk '/^  - \[ \] 5\.2 / { on=1 } /^  - \[ \] 5\.3 / { on=0 } on { print }' "$1")"
    [[ "${section}" == *'非 tty stdin，自動重新載入、開窗並尋找新 shell'* ]] &&
    [[ "${section}" == *'主觀項目，不影響 rc'* ]] &&
    [[ "${section}" == *'IPC 成功只代表請求已送出，最終仍須通過新 shell 的客觀證據'* ]] &&
    [[ "${section}" == *'10 秒是搜尋預算，並非整段確認的硬上限'* ]] &&
    [[ "${section}" == *'證據探測不受該搜尋期限截斷'* ]] &&
    [[ "${section}" == *'收尾掃描與升級的等待上限為 15 秒'* ]] &&
    [[ "${section}" == *'開始值加 4，第 3 秒起不再開始重試（開始值加 3）'* ]] &&
    [[ "${section}" == *'guard_timed 1 ps'* ]] &&
    [[ "${section}" == *'guard_timed 1 kill'* ]] &&
    [[ "${section}" == *'1 秒後 TERM，最多再等 10 秒才 KILL'* ]] &&
    [[ "${section}" == *'root 消失後另查 PGID／SID 的 session 探測'* ]] &&
    [[ "${section}" == *'TIMEOUT_SHORT=180 秒，TERM 後最多再等 10 秒才 KILL'* ]] &&
    [[ "${section}" == *'namespace 的本機 readlink 沒有獨立 timeout'* ]] &&
    [[ "${section}" == *'還原祖先鏈最多 64 次 ps 也各自計時'* ]] &&
    [[ "${section}" == *'套用模式的例外：到期時若先前已記錄非 fish 候選'* ]] &&
    [[ "${section}" == *'穩定非 fish 回 rc=1，候選已消失或無法確認回 rc=3'* ]] &&
    [[ "${section}" == *'確認 session 的 PGID／SID 已無存活成員後才移除目錄'* ]] &&
    [[ "${section}" == *'成員仍存活或 session 檢查無法判定時，保留目錄並回非零'* ]] &&
    [[ "${section}" != *'必須輸入 PID'* ]] &&
    [[ "${section}" != *'證據探測須在搜尋預算內完成'* ]] &&
    [[ "${section}" != *'session 未確認空也可刪'* ]] &&
    [[ "${section}" != *'最後一次外部探測最多 1 秒，因此總上限為 5 秒'* ]]
}

@test "5.2 documents automatic window evidence, deadlines and safe cleanup" {
    _window_contract "${DOC}"
}

@test "5.2 guard rejects missing or contradictory window promises" {
    local phrase altered
    for phrase in \
        '非 tty stdin，自動重新載入、開窗並尋找新 shell' \
        '主觀項目，不影響 rc' \
        'IPC 成功只代表請求已送出，最終仍須通過新 shell 的客觀證據' \
        '10 秒是搜尋預算，並非整段確認的硬上限' \
        '證據探測不受該搜尋期限截斷' \
        '收尾掃描與升級的等待上限為 15 秒' \
        '開始值加 4，第 3 秒起不再開始重試（開始值加 3）' \
        'guard_timed 1 ps' \
        'guard_timed 1 kill' \
        '1 秒後 TERM，最多再等 10 秒才 KILL' \
        'root 消失後另查 PGID／SID 的 session 探測' \
        'TIMEOUT_SHORT=180 秒，TERM 後最多再等 10 秒才 KILL' \
        'namespace 的本機 readlink 沒有獨立 timeout' \
        '還原祖先鏈最多 64 次 ps 也各自計時' \
        '套用模式的例外：到期時若先前已記錄非 fish 候選' \
        '穩定非 fish 回 rc=1，候選已消失或無法確認回 rc=3' \
        '確認 session 的 PGID／SID 已無存活成員後才移除目錄' \
        '成員仍存活或 session 檢查無法判定時，保留目錄並回非零'; do
        altered="${BATS_TEST_TMPDIR}/acceptance.md"
        PHRASE="${phrase}" awk '{ gsub(ENVIRON["PHRASE"], "removed"); print }' "${DOC}" > "${altered}"
        run _window_contract "${altered}"
        assert_failure
    done
    for phrase in '必須輸入 PID' '證據探測須在搜尋預算內完成' 'session 未確認空也可刪' '最後一次外部探測最多 1 秒，因此總上限為 5 秒'; do
        PHRASE="${phrase}" awk '/^  - \[ \] 5\.2 / { print; print ENVIRON["PHRASE"]; next } { print }' "${DOC}" > "${altered}"
        run _window_contract "${altered}"
        assert_failure
    done
}
