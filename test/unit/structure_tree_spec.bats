#!/usr/bin/env bats
# The structure tree reflects the M3 paths and box interface (#1017).
load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    DOC="${BATS_TEST_TMPDIR}/structure.md"
    cp "${BATS_TEST_DIRNAME}/../../doc/structure.md" "${DOC}"
    ROOT="${BATS_TEST_DIRNAME}/../.."
    JUSTFILE="${BATS_TEST_TMPDIR}/justfile"
    cp "${ROOT}/justfile" "${JUSTFILE}"
}

_has_token() {
    tr ' /' '\n' <"$1" | grep -qxF "$2"
}

_tree_check() {
    local doc="$1" root="$2" tree="${BATS_TEST_TMPDIR}/tree" section="${BATS_TEST_TMPDIR}/section" file name names
    awk '/^worktool\/$/ { inside=1 } inside && /^```$/ { exit } inside { print }' "${doc}" >"${tree}"
    [[ -s "${tree}" ]] || return 1
    awk '/│   ├── verify\// { inside=1; next } inside && /│   └── box\// { exit } inside { print }' "${tree}" >"${section}"
    [[ -s "${section}" ]] || return 1
    for file in "${root}"/script/verify/*; do
        [[ -f "${file}" ]] || continue
        name="${file##*/}"
        _has_token "${section}" "${name}" || return 1
    done
    awk '/├── lib\// { inside=1; next } inside && /├── box\// { exit } inside { print }' "${tree}" >"${section}"
    for name in config_backup.sh distrobox_manager.sh guard.sh realbox_interrupt.sh verify_run.sh; do
        [[ -f "${root}/lib/${name}" ]] && _has_token "${section}" "${name}" || return 1
    done
    awk '/│   └── helper\// { inside=1; next } inside && /├── dockerfile\// { exit } inside { print }' "${tree}" >"${section}"
    for name in diagnostics.bash interrupt_load.bash realbox_window.bash; do
        [[ -f "${root}/test/helper/${name}" ]] && _has_token "${section}" "${name}" || return 1
    done
    awk '/│   │   └── fixture\// { inside=1; next } inside && /│   ├── matrix\// { exit } inside { print }' "${tree}" >"${section}"
    for file in "${root}"/test/unit/fixture/* "${root}"/test/unit/fixture/adr/*; do
        [[ -f "${file}" ]] || continue
        name="${file##*/}"
        _has_token "${section}" "${name}" || return 1
    done
    awk '/│   ├── evidence\// { inside=1; next } inside && /│   └── diagram\// { exit } inside { print }' "${tree}" >"${section}"
    for file in "${root}"/doc/evidence/* "${root}"/doc/evidence/negative/*; do
        [[ -f "${file}" ]] || continue
        name="${file##*/}"
        _has_token "${section}" "${name}" || return 1
    done
    grep -F 'guard.sh' "${tree}" | grep -qF '失敗封閉的狀態原語，區分不存在與無法判定' || return 1
    grep -F 'evidence/' "${tree}" | grep -qF '保留既有 review 紀錄，新增審查紀錄放 PR 留言或 .agents/state/' || return 1
    awk '/^`test_sh_spec`/ { inside=1 } inside && /WORKTOOL_TEST_JOBS=4/ { exit } inside { print }' "${doc}" >"${section}"
    names="${BATS_TEST_TMPDIR}/names"
    awk '/^test_shard_has_unexpected_skip\(\)/ { inside=1 } inside && /\$0 == "/ { split($0, a, "\""); print a[2] } inside && /^}/ { exit }' "${root}/lib/test_shard.sh" >"${names}" || return 1
    [[ "$(wc -l <"${names}")" -eq 3 ]] || return 1
    while IFS= read -r name; do
        [[ -n "${name}" ]] && grep -qF "${name}" "${section}" || return 1
    done <"${names}"
    grep -F 'justfile.box' "${tree}" >"${section}" || return 1
    ! grep -qE 'M3.*(再加|adds).*rm' "${section}"
}

@test "structure tree documents the M3 paths without a future box rm claim" {
    run _tree_check "${DOC}" "${ROOT}"
    assert_success
}

@test "missing paths and stale rm claim in the tree fail even when mentioned elsewhere" {
    sed -i 's/config_backup_paths.sh/missing-path.sh/' "${DOC}"
    run _tree_check "${DOC}" "${ROOT}"; assert_failure
    cp "${BATS_TEST_DIRNAME}/../../doc/structure.md" "${DOC}"
    sed -i 's/config_backup.sh/missing-backup.sh/' "${DOC}"
    run _tree_check "${DOC}" "${ROOT}"; assert_failure
    cp "${BATS_TEST_DIRNAME}/../../doc/structure.md" "${DOC}"
    sed -i '/justfile.box.*命名空間/s/$/ (M3 再加 rm)/' "${DOC}"
    run _tree_check "${DOC}" "${ROOT}"; assert_failure
}

@test "helper, fixture, evidence and policy removals fail without substring substitutes" {
    local name
    for name in diagnostics.bash realbox_tool.sh verify-image.md; do
        cp "${BATS_TEST_DIRNAME}/../../doc/structure.md" "${DOC}"
        sed -i "s/${name}/${name}.obsolete/g" "${DOC}"
        run _tree_check "${DOC}" "${ROOT}"; assert_failure
    done
    cp "${BATS_TEST_DIRNAME}/../../doc/structure.md" "${DOC}"
    sed -i 's/區分不存在與無法判定/回傳狀態/' "${DOC}"
    run _tree_check "${DOC}" "${ROOT}"; assert_failure
    cp "${BATS_TEST_DIRNAME}/../../doc/structure.md" "${DOC}"
    sed -i 's/保留既有 review 紀錄/刪除既有 review 紀錄/' "${DOC}"
    run _tree_check "${DOC}" "${ROOT}"; assert_failure
    cp "${BATS_TEST_DIRNAME}/../../doc/structure.md" "${DOC}"
    sed -i 's/verify_run: HUP under CPU load always finishes before cleanup/missing case/' "${DOC}"
    run _tree_check "${DOC}" "${ROOT}"; assert_failure
}

@test "missing or incomplete runner names fail closed" {
    local fake="${BATS_TEST_TMPDIR}/fake"
    mkdir -p "${fake}/lib"
    cp "${ROOT}/lib/test_shard.sh" "${fake}/lib/test_shard.sh"
    sed -i "/\\\$0 == \"/d" "${fake}/lib/test_shard.sh"
    # Keep all other paths real so the failure is the missing runner list.
    ln -s "${ROOT}/script" "${fake}/script"
    ln -s "${ROOT}/test" "${fake}/test"
    ln -s "${ROOT}/doc" "${fake}/doc"
    for name in config_backup.sh distrobox_manager.sh guard.sh realbox_interrupt.sh verify_run.sh; do
        ln -s "${ROOT}/lib/${name}" "${fake}/lib/${name}"
    done
    run _tree_check "${DOC}" "${fake}"; assert_failure
    cp "${ROOT}/lib/test_shard.sh" "${fake}/lib/test_shard.sh"
    sed -i "/\\\$0 == \"/ { /||/ {d;} }" "${fake}/lib/test_shard.sh"
    run _tree_check "${DOC}" "${fake}"; assert_failure
}

_check_root_box_comment() {
    local comment="${BATS_TEST_TMPDIR}/box-comment"
    awk '/^mod\? box / { if (found++ || previous !~ /^# /) exit 1; print previous } { previous=$0 } END { if (found != 1) exit 1 }' "$1" >"${comment}" || return 1
    [[ -s "${comment}" ]] || return 1
    ! grep -qiE 'M3.*(再加|adds).*rm' "${comment}"
}

@test "root box listing does not promise a future rm command" {
    run _check_root_box_comment "${JUSTFILE}"
    assert_success
    sed -i '/^# Dev box lifecycle:/s/$/ (M3 adds rm)/' "${JUSTFILE}"
    run _check_root_box_comment "${JUSTFILE}"
    assert_failure
}

@test "box listing check is scoped and fails if the declaration or comment is absent" {
    sed -i '/^# Self-test:/s/$/ (M3 adds rm)/' "${JUSTFILE}"
    run _check_root_box_comment "${JUSTFILE}"; assert_success
    sed -i '/^mod? box /d' "${JUSTFILE}"
    run _check_root_box_comment "${JUSTFILE}"; assert_failure
    cp "${ROOT}/justfile" "${JUSTFILE}"
    sed -i '/^# Dev box lifecycle:/d' "${JUSTFILE}"
    run _check_root_box_comment "${JUSTFILE}"; assert_failure
}
