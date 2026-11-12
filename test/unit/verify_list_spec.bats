#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    bats_require_minimum_version 1.5.0
    REAL_JUST="$(command -v just)"
    export CALLS="${BATS_TEST_TMPDIR}/calls"
    export HOME="${BATS_TEST_TMPDIR}/home"
    export XDG_CONFIG_HOME="${HOME}/.config" XDG_CACHE_HOME="${HOME}/.cache"
    export XDG_DATA_HOME="${HOME}/.local/share"
    mkdir -p "${BATS_TEST_TMPDIR}/bin" "${HOME}"
    local tool
    for tool in distrobox docker gh grep; do
        cat >"${BATS_TEST_TMPDIR}/bin/${tool}" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${0##*/} $*" >>"${CALLS}"
exit 99
STUB
        chmod +x "${BATS_TEST_TMPDIR}/bin/${tool}"
    done
    export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

# Capture stdout separately: recipe echo and diagnostics belong to stderr.
_assert_documented_list() {
    local action="$1" expected="$2" actual="" line
    run --separate-stderr "${REAL_JUST}" --justfile "${REPO_ROOT}/justfile" verify "${action}" --list
    assert_success
    for line in "${lines[@]}"; do
        actual+="${line%% *}"$'\n'
    done
    assert_equal "${actual%$'\n'}" "${expected}"
    [ ! -e "${CALLS}" ]
}

@test "list: all six actions expose their documented IDs in order through just" {
    _assert_documented_list ui '1.1'
    _assert_documented_list gate $'2.1\n2.2\n2.3\n2.4'
    _assert_documented_list setup $'3.1\n3.2\n3.3\n3.4\n3.5\n3.6\n3.7\n3.8\n3.9\n3.10\n3.11\n3.12\n3.13'
    _assert_documented_list diagram '4.1'
    _assert_documented_list realbox $'5.1\n5.2\n5.2.1\n5.2.2\n5.2.3\n5.3\n5.4'
    _assert_documented_list evidence $'6.1\n6.2\n6.3'
    assert_equal "$(find "${HOME}" -mindepth 1 -print)" ''
}

@test "diagram and realbox list titles and advertise list without running checks" {
    local action line stderr
    for action in diagram realbox; do
        run --separate-stderr "${REAL_JUST}" --justfile "${REPO_ROOT}/justfile" verify "${action}" --list
        assert_success
        for line in "${lines[@]}"; do
            [[ "${line}" =~ ^[0-9]+(\.[0-9]+)+\ \ [^[:space:]].* ]]
        done
        run --separate-stderr "${REAL_JUST}" --justfile "${REPO_ROOT}/justfile" verify "${action}" --help
        assert_success
        [[ "${stderr}" == *'List the item ids and their titles'* ]]
    done
    [ ! -e "${CALLS}" ]
    assert_equal "$(find "${HOME}" -mindepth 1 -print)" ''
}

@test "diagram and realbox validate arguments before help or list" {
    local action option stderr
    for action in diagram realbox; do
        for option in --help --list; do
            run --separate-stderr "${REAL_JUST}" --justfile "${REPO_ROOT}/justfile" verify "${action}" "${option}" --bogus
            assert_failure 2
            [[ "${stderr}" == *"${action}.sh: unknown option '--bogus' (see --help)"* ]]
        done
    done
    [ ! -e "${CALLS}" ]
}
