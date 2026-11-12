#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

_ownership_doc_valid() {
    local doc="$1" content required
    content="$(cat "${doc}")"
    for required in \
        "所有權須以 assemble 前確認盒子不存在、執行後合法列表確認盒子存在為證據，才把該盒的 container ID 寫入 \`created-box\`" \
        '中斷後 assemble 回非零時，先停止本輪子行程群組，再於本次 realbox 執行內以合法列表確認盒子存在並記下 ID' \
        '才取得清理所有權' \
        '列表失敗或無法解析時拒絕刪盒、回非零並保留證據' \
        "缺少 \`created-box\` 代表本輪未確認盒子所有權" \
        '拒絕刪盒、保留嘗試紀錄並回非零'; do
        [[ "${content}" == *"${required}"* ]] || return 1
    done
    [[ "${content}" == *'中斷後 assemble 回非零時，先停止本輪子行程群組，再於本次 realbox 執行內以合法列表確認盒子存在並記下 ID'*'才取得清理所有權'* ]] || return 1
}

@test "acceptance documents box ownership and fail-closed cleanup" {
    run _ownership_doc_valid "${REPO_ROOT}/doc/acceptance.md"
    assert_success
}

@test "ownership documentation guard rejects missing boundaries" {
    local original="${REPO_ROOT}/doc/acceptance.md" copy="${BATS_TEST_TMPDIR}/acceptance.md" phrase
    for phrase in \
        "所有權須以 assemble 前確認盒子不存在、執行後合法列表確認盒子存在為證據，才把該盒的 container ID 寫入 \`created-box\`" \
        '中斷後 assemble 回非零時，先停止本輪子行程群組，再於本次 realbox 執行內以合法列表確認盒子存在並記下 ID' \
        '才取得清理所有權' \
        '列表失敗或無法解析時拒絕刪盒、回非零並保留證據' \
        "缺少 \`created-box\` 代表本輪未確認盒子所有權" \
        '拒絕刪盒、保留嘗試紀錄並回非零'; do
        PHRASE="${phrase}" awk '{ p = index($0, ENVIRON["PHRASE"]); if (p) $0 = substr($0, 1, p-1) "removed" substr($0, p+length(ENVIRON["PHRASE"])); print }' "${original}" >"${copy}"
        run _ownership_doc_valid "${copy}"
        assert_failure
    done
}

@test "ownership guard rejects truncated or reversed causality" {
    local original="${REPO_ROOT}/doc/acceptance.md" copy="${BATS_TEST_TMPDIR}/acceptance.md" from to
    for from in \
        '先停止本輪子行程群組，再於本次 realbox 執行內以合法列表確認盒子存在並記下 ID' \
        'assemble 前確認盒子不存在、執行後合法列表確認盒子存在為證據'; do
        case "${from}" in
            先停止*) to='先確認盒子存在並記下 ID，再停止本輪子行程群組' ;;
            *) to='執行後確認盒子不存在、事前確認盒子存在為證據' ;;
        esac
        FROM="${from}" TO="${to}" awk '{ p = index($0, ENVIRON["FROM"]); if (p) $0 = substr($0, 1, p-1) ENVIRON["TO"] substr($0, p+length(ENVIRON["FROM"])); print }' "${original}" >"${copy}"
        run _ownership_doc_valid "${copy}"
        assert_failure
    done
    from='再於本次 realbox 執行內以合法列表確認盒子存在並記下 ID'
    FROM="${from}" awk '{ p = index($0, ENVIRON["FROM"]); if (p) $0 = substr($0, 1, p-1) substr($0, p+length(ENVIRON["FROM"])); print }' "${original}" >"${copy}"
    run _ownership_doc_valid "${copy}"
    assert_failure
}
