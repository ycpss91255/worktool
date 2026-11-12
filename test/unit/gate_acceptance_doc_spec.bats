#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    DOC="${BATS_TEST_TMPDIR}/acceptance.md"
    cp "${REPO_ROOT}/doc/acceptance.md" "${DOC}"
}

_check_gate_contract() {
    local section
    section="$(sed -n '/^  - \[ \] 2\.3 /,/^  - \[ \] 2\.4 /p' "$1")"
    [[ "${section}" == *'清單中的每個案例各出現一次、不能多也不能少'* ]] || return 1
    [[ "${section}" == *"只適用於 pattern 選中的 \`ok\` 行（含 ghostty）"* ]] || return 1
    [[ "${section}" == *"其餘案例的失敗由 \`^not ok\` 與 tier rc 擋住"* ]] || return 1
    [[ "${section}" == *'mntns 相等由 bats 案例保證'* ]] || return 1
    [[ "${section}" == *"\`gate.sh\` 只檢查 \`mntns=mnt:[數字]\` 格式與字面 \`== dev container\`"* ]]
}

@test "gate acceptance document retains its verification boundary" {
    run _check_gate_contract "${DOC}"
    assert_success
}

@test "gate contract rejects broadened counts and misplaced namespace responsibility" {
    local mutation
    for mutation in count selected failure equality format; do
        cp "${REPO_ROOT}/doc/acceptance.md" "${DOC}"
        case "${mutation}" in
            count) sed -i 's/清單中的每個案例各出現一次、不能多也不能少/案例可重複或缺漏/' "${DOC}" ;;
            selected) sed -i 's/只適用於 pattern 選中的/適用於所有/' "${DOC}" ;;
            failure) sed -i 's/其餘案例的失敗由/其餘案例的失敗不由/' "${DOC}" ;;
            equality) sed -i 's/mntns 相等由 bats 案例保證/mntns 相等由 gate 保證/' "${DOC}" ;;
            format) sed -i "s/只檢查 \`mntns=mnt:\\[數字\\]\` 格式/檢查 namespace 相等/" "${DOC}" ;;
        esac
        run _check_gate_contract "${DOC}"
        assert_failure
    done
}
