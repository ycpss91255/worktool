#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    DOC="${BATS_TEST_TMPDIR}/acceptance.md"
    cp "${REPO_ROOT}/doc/acceptance.md" "${DOC}"
}

_check_setup_contract() {
    local doc="$1" paragraph section item
    paragraph="$(sed -n '/受管檔案是.*使用者的/p' "${doc}")"
    for item in 3.1 3.2 3.3 3.5 3.6 3.7 3.8 3.9 3.10 3.11 3.12 3.13; do
        [[ "${paragraph}" == *"${item} /"* || "${paragraph}" == *"${item} ——"* ]] || return 1
    done
    [[ "${paragraph}" == *"在跑 setup **之前**就先把臨時 HOME 的 ghostty 設定與 \`~/.tmux.conf\` 種進三行看得出來的使用者內容"* ]] || return 1
    [[ "${paragraph}" == *'每一次寫入、改寫、移除之後再查一次'* ]] || return 1
    [[ "${paragraph}" == *'內容必須還是那三行、順序不變、一行不多一行不少'* ]] || return 1
    [[ "${paragraph}" == *'檔尾空白行與最後換行也必須相同'* ]] || return 1
    section="$(sed -n '/^  - \[ \] 3\.11 /,/^  - \[ \] 3\.12 /p' "${doc}")"
    [[ "${section}" == *"每次寫入、改寫與移除後都檢查 \`~/.tmux.conf\` 的使用者內容"* ]]
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

@test "setup and gate acceptance documents retain their verification boundaries" {
    run _check_setup_contract "${DOC}"
    assert_success
    run _check_gate_contract "${DOC}"
    assert_success
}

@test "setup contract rejects missing seeded items, tmux checks and byte boundaries" {
    local mutation
    for mutation in item tmux ending seed timing contents before targets; do
        cp "${REPO_ROOT}/doc/acceptance.md" "${DOC}"
        case "${mutation}" in
            item) sed -i 's@ / 3\.11 /@ /@' "${DOC}" ;;
            tmux) sed -i 's/每次寫入、改寫與移除後都檢查/只在寫入後檢查/' "${DOC}" ;;
            ending) sed -i 's/檔尾空白行與最後換行也必須相同/檔尾可不同/' "${DOC}" ;;
            seed) sed -i 's/種進三行看得出來的使用者內容/只種一行/' "${DOC}" ;;
            before) sed -i 's/在跑 setup \*\*之前\*\*/在跑 setup 之後/' "${DOC}" ;;
            targets) sed -i "s/ghostty 設定與 \`~\\/.tmux.conf\`/ghostty 設定/" "${DOC}" ;;
            timing) sed -i 's/每一次寫入、改寫、移除之後再查一次/只在寫入後檢查/' "${DOC}" ;;
            contents) sed -i 's/內容必須還是那三行、順序不變、一行不多一行不少/內容可以增減或換序/' "${DOC}" ;;
        esac
        run _check_setup_contract "${DOC}"
        assert_failure
    done
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
