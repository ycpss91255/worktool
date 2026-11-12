#!/usr/bin/env bats
# Acceptance output classifications stay next to the criteria (#1046).
load '../helper/common'

_check_output_types() {
    local doc="$1"
    awk '
        /預期看到資訊/ {
            count++
            if (getline <= 0 || $0 !~ /^[[:space:]]*輸出類型：/) exit 1
            if ($0 !~ /固定判準|工具版本會影響的輸出|動態示例/) exit 1
        }
        END { if (count == 0) exit 1 }
    ' "${doc}" || return 1
    grep -qF '預期輸出分為固定判準、工具版本會影響的輸出及動態示例' "${doc}" || return 1
    grep -qF '明列的失敗、順序或清理條件' "${doc}" || return 1
    awk '
        /^## M3 / { m3=1 }
        m3 && /^  - \[ \] 5\.1 / { item=51; next }
        m3 && /^  - \[ \] 5\.2 / { item=52; next }
        m3 && /^  - \[ \] 5\.3 / { item=0 }
        item && /^[[:space:]]*````?text/ {
            n[item]++
            if (item == 51 && n[item] == 1 && previous !~ /動態示例.*順序、狀態與結束碼為固定判準/) exit 1
            if (item == 51 && n[item] == 2 && previous !~ /工具版本會影響.*phase、失敗與清理條件固定/) exit 1
            if (item == 51 && n[item] == 3 && previous !~ /動態示例.*未判定、結束碼與清理條件固定/) exit 1
            if (item == 52 && n[item] == 1 && previous !~ /固定判準.*警告及人工清理條件固定/) exit 1
            if (item == 52 && n[item] == 2 && previous !~ /動態示例.*測試替身明列值、狀態順序及結束碼固定/) exit 1
            if (item == 52 && n[item] == 3 && previous !~ /工具版本會影響.*phase、失敗與清理條件固定/) exit 1
            if (item == 52 && n[item] == 4 && previous !~ /固定判準.*PID 與 namespace 是 fixture 的固定值/) exit 1
        }
        { previous=$0 }
        END { if (n[51] != 3 || n[52] != 4) exit 1 }
    ' "${doc}" || return 1
    for item in 1.1 3.11 3.12 3.13 4.1 5.4; do
        awk -v item="${item}" '
            /^## M3 / { m3=1 }
            m3 && index($0, "- [ ] " item " ") { active=1; next }
            active && /- \[ \]/ { exit }
            active && /^[[:space:]]*````?text/ {
                if (previous !~ /輸出類型：.*固定判準/) exit 1
                if (item == "5.4" && previous !~ /六格順序與結束碼固定/) exit 1
                found=1; exit
            }
            { previous=$0 }
            END { if (!found) exit 1 }
        ' "${doc}" || return 1
    done
    for item in 6.1 6.2 6.3; do
        awk -v item="${item}" '
            /^  - 6\.[123]：/ { active=(index($0, "  - " item "：") == 1) }
            /^- TDD 證據：/ { active=0 }
            active && /輸出類型：固定判準/ { found=1 }
            END { if (!found) exit 1 }
        ' "${doc}" || return 1
    done
    grep -qF '測試替身中的明列值' "${doc}" || return 1
    grep -qF 'SOME FAILED、失敗條件與結束碼為固定判準' "${doc}" || return 1
    grep -qF '本項要求三列與結束碼' "${doc}" || return 1
}

@test "acceptance expected outputs declare their comparison type" {
    run _check_output_types "${REPO_ROOT}/doc/acceptance.md"
    assert_success
}

@test "missing or displaced output classifications are rejected" {
    local doc="${BATS_TEST_TMPDIR}/acceptance.md"
    awk '/預期看到資訊/ && !done { print; getline; sub(/輸出類型：/, "缺少類型："); print; done=1; next } { print }' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _check_output_types "${doc}"
    assert_failure
    awk '/預期看到資訊/ && !done { print; getline; saved=$0; print "      misplaced"; print saved; done=1; next } { print }' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _check_output_types "${doc}"
    assert_failure
}

@test "busy, stream, matrix and fixture comparison boundaries are required" {
    local doc="${BATS_TEST_TMPDIR}/acceptance.md" phrase
    for phrase in '六格順序與結束碼固定' '測試替身中的明列值' 'SOME FAILED、失敗條件與結束碼為固定判準' '本項要求三列與結束碼'; do
        sed "s/${phrase}/removed boundary/" "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
        run _check_output_types "${doc}"
        assert_failure
    done
    awk '
        !changed && /輸出類型：工具版本會影響的輸出；實測值/ {
            sub(/輸出類型：工具版本會影響的輸出；實測值/, "removed stream type")
            changed=1
        }
        { print }
        END { if (!changed) exit 1 }
    ' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _check_output_types "${doc}"
    assert_failure
}

@test "item classifications cannot be removed or moved to another item" {
    local doc="${BATS_TEST_TMPDIR}/acceptance.md" item
    for item in 1.1 3.11 3.12 3.13 4.1 5.4; do
        awk -v item="${item}" '
            /^## M3 / { m3=1 }
            m3 && index($0, "- [ ] " item " ") { active=1 }
            active && /輸出類型：/ { sub(/輸出類型：/, "移除："); active=0 }
            { print }
        ' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
        printf "\n輸出類型：固定判準\n" >>"${doc}"
        run _check_output_types "${doc}"
        assert_failure
    done
}

@test "matrix classification cannot be downgraded to dynamic only" {
    local doc="${BATS_TEST_TMPDIR}/acceptance.md"
    sed 's/輸出類型：固定判準；六格/輸出類型：動態示例；六格/' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _check_output_types "${doc}"
    assert_failure
}

@test "each realbox output block rejects downgraded or displaced classification" {
    local doc="${BATS_TEST_TMPDIR}/acceptance.md" item number action
    for item in 51 52; do
        for number in $(seq 1 "$([ "${item}" = 51 ] && printf 3 || printf 4)"); do
            for action in downgrade move; do
                awk -v target="${item}" -v number="${number}" -v action="${action}" '
                    /^## M3 / { m3=1 }
                    m3 && /^  - \[ \] 5\.1 / { item=51 }
                    m3 && /^  - \[ \] 5\.2 / { item=52 }
                    m3 && /^  - \[ \] 5\.3 / { item=0 }
                    item && /輸出類型：/ { saved=$0; next }
                    item && /^[[:space:]]*````?text/ {
                        n[item]++
                        if (item == target && n[item] == number) {
                            if (action == "downgrade") saved="      輸出類型：動態示例"
                            else saved="      misplaced"
                        }
                    }
                    { if (saved != "") { print saved; saved="" } print }
                    END { if (saved != "") print saved }
                ' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
                run _check_output_types "${doc}"
                assert_failure
            done
        done
    done
}

@test "evidence output classifications stay within their own sections" {
    local doc="${BATS_TEST_TMPDIR}/acceptance.md" item
    for item in 6.1 6.2 6.3; do
        awk -v item="${item}" '
            /^  - 6\.[123]：/ { active=(index($0, "  - " item "：") == 1) }
            active && /輸出類型：固定判準/ { sub(/輸出類型：固定判準/, "輸出類型：動態示例"); active=0 }
            { print }
        ' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
        printf "\n輸出類型：固定判準\n" >>"${doc}"
        run _check_output_types "${doc}"
        assert_failure
    done
}
