#!/usr/bin/env bats
# M2's manual host cleanup requires an explicit ownership warning (#1024).
load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    DOC="${BATS_TEST_TMPDIR}/acceptance.md"
    cp "${BATS_TEST_DIRNAME}/../../doc/acceptance.md" "${DOC}"
}

_check_warning() {
    local section="${BATS_TEST_TMPDIR}/m2-71" pre="${BATS_TEST_TMPDIR}/pre"
    awk '/^  - \[ \] 7\.1 / { inside=1 } inside && /^## M3 / { exit } inside { print }' "$1" >"${section}"
    grep -qFx '      just box assemble' "${section}" || return 1
    awk '/^      just box assemble$/ { exit } { print }' "${section}" >"${pre}"
    grep -qF '請人工確認沒有同名' "${pre}" || return 1
    grep -qF '若已存在或無法確認，勿執行此項' "${pre}" || return 1
    grep -qF '只可清除本輪建立且已確認屬於本輪的盒' "${pre}" || return 1
    grep -qF '無法確認所有權時勿按名稱刪除' "${pre}" || return 1
    grep -qF '以下指令不會自動檢查' "${pre}" || return 1
    grep -qF '      distrobox rm -f dev' "${section}"
}

@test "M2 host acceptance warns before the manual cleanup sequence" {
    run _check_warning "${DOC}"
    assert_success
}

@test "missing or misplaced ownership warning does not satisfy M2 7.1" {
    sed -i '/請人工確認沒有同名/d' "${DOC}"
    run _check_warning "${DOC}"; assert_failure
    printf '%s\n' '請人工確認沒有同名；若已存在或無法確認，勿執行此項；只可清除本輪建立且已確認屬於本輪的盒；無法確認所有權時勿按名稱刪除；以下指令不會自動檢查' >>"${DOC}"
    run _check_warning "${DOC}"; assert_failure
}

@test "missing assemble anchor and warning moved after it fail" {
    sed -i '/^      just box assemble$/d' "${DOC}"
    run _check_warning "${DOC}"; assert_failure
    cp "${BATS_TEST_DIRNAME}/../../doc/acceptance.md" "${DOC}"
    awk '/請人工確認沒有同名/ { warning=$0; next } /^      just box assemble$/ && !moved { print; print warning; moved=1; next } { print }' "${DOC}" >"${DOC}.new"
    mv "${DOC}.new" "${DOC}"
    run _check_warning "${DOC}"; assert_failure
}
