#!/usr/bin/env bats
# Verify the documented acceptance tool dependencies against script preconditions.

load "${BATS_TEST_DIRNAME}/../helper/common"

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
    local tools derived expected documented
    local -a scripts=(script/verify/ui.sh script/verify/gate.sh script/verify/setup.sh
        script/verify/diagram.sh script/verify/realbox.sh script/verify/evidence.sh)
    tools="$(sed -n '/^- 驗收工具:/p' "${REPO_ROOT}/doc/acceptance.md")"
    [[ -n "${tools}" ]] || return 1
    derived="$(verify_item_tools "${REPO_ROOT}" "${scripts[@]}")"
    [[ -n "${derived}" ]] || return 1
    expected="$(awk -F'\t' 'NR == FNR { skip[$1] = 1; next } !($1 in skip)' \
        <(printf '%s\n' "${ACCEPTANCE_UNANNOTATED_TOOLS[@]}") - <<<"${derived}")"
    [[ -n "${expected}" ]] || return 1
    documented="$(_doc_tool_items <<<"${tools}" | LC_ALL=C sort -u)"
    assert_equal "${documented}" "${expected}"
    [[ "${tools}" == *"\`awk\` / \`grep\` / \`sed\`"* ]]
    [[ "${tools}" == *'coreutils 指令'* ]]

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

@test "tool annotations distinguish a missing item from the documented matrix" {
    local actual expected
    expected="$(printf '%s\t%s\n' example 9.1 example 9.2)"
    actual="$(_doc_tool_items <<<"\`example\`(package;9.1 / 9.2 用)" | LC_ALL=C sort -u)"
    assert_equal "${actual}" "${expected}"
    actual="$(_doc_tool_items <<<"\`example\`(package;9.1 用)" | LC_ALL=C sort -u)"
    [[ "${actual}" != "${expected}" ]]
}

@test "tool derivation rejects an unresolved source graph" {
    load "${BATS_TEST_DIRNAME}/../helper/graph"
    load "${BATS_TEST_DIRNAME}/../helper/verify_tools"
    local tree="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${tree}/script/verify"
    cat >"${tree}/script/verify/x.sh" <<'SCRIPT'
source "${UNKNOWN}/dependency.sh"
_dispatch() {
    case "$1" in
        9.1) _item_9_1 ;;
    esac
}
_item_9_1() { guard_require zstd; }
SCRIPT
    run verify_item_tools "${tree}" script/verify/x.sh
    assert_failure
    assert_output --partial 'cannot resolve the source graph'
}

@test "tool derivation rejects missing entries, empty items, cleanup and child targets" {
    load "${BATS_TEST_DIRNAME}/../helper/graph"
    load "${BATS_TEST_DIRNAME}/../helper/verify_tools"
    local tree="${BATS_TEST_TMPDIR}/repo" mode
    mkdir -p "${tree}/script/verify"
    cat >"${tree}/script/verify/good.sh" <<'SCRIPT'
_dispatch() {
    case "$1" in
        9.1) _item_9_1 ;;
    esac
}
_item_9_1() (
    guard_require zstd
)
SCRIPT
    for mode in missing empty cleanup target child; do
        case "${mode}" in
            missing) printf '%s\n' '_item_9_2_missing() { :; }' >"${tree}/body" ;;
            empty) printf '%s\n' '_item_9_2() { :; }' >"${tree}/body" ;;
            cleanup) printf '%s\n' '_item_9_2() { guard_require xz; _cleanup_push unknown; }' >"${tree}/body" ;;
            target) cat >"${tree}/body" <<'SCRIPT'
_item_9_2() { guard_require xz; _cleanup_push known; }
_cleanup_run() {
    case "$1" in
        known) _missing_cleanup ;;
    esac
}
SCRIPT
                ;;
            child) printf '%s\n' "_item_9_2() { guard_require xz; bash \"\${SCRIPT_DIR}/bad.sh\" 9.3; }" >"${tree}/body" ;;
        esac
        cat >"${tree}/script/verify/bad.sh" <<'SCRIPT'
_dispatch() {
    case "$1" in
        9.2) _item_9_2 ;;
    esac
}
SCRIPT
        cat "${tree}/body" >>"${tree}/script/verify/bad.sh"
        run verify_item_tools "${tree}" script/verify/good.sh script/verify/bad.sh
        assert_failure
        case "${mode}" in
            missing) assert_output --partial 'unresolved entry _item_9_2' ;;
            empty) assert_output --partial 'no tools for item 9.2' ;;
            cleanup) assert_output --partial 'unknown cleanup token unknown' ;;
            target) assert_output --partial 'unknown cleanup target _missing_cleanup' ;;
            child) assert_output --partial 'unknown child item 9.3' ;;
        esac
    done
}
