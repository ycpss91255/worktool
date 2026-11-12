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

@test "setup acceptance document retains its verification boundary" {
    run _check_setup_contract "${DOC}"
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
