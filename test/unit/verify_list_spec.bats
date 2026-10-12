#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    REAL_JUST="$(command -v just)"
    CALLS="${BATS_TEST_TMPDIR}/calls"
    export CALLS
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

@test "diagram --list lists documented item 4.1 without running checks" {
    run "${REAL_JUST}" --justfile "${REPO_ROOT}/justfile" verify diagram --list
    assert_success
    assert_equal "${#lines[@]}" 2
    assert_line --index 1 --regexp '^4\.1([[:space:]]|$)'
    [ ! -e "${CALLS}" ]
}

@test "realbox --list lists documented items without opt-in or external calls" {
    run "${REAL_JUST}" --justfile "${REPO_ROOT}/justfile" verify realbox --list
    assert_success
    assert_equal "${#lines[@]}" 8
    local index=1 item
    for item in 5.1 5.2 5.2.1 5.2.2 5.2.3 5.3 5.4; do
        assert_equal "${lines[index]%% *}" "${item}"
        index=$((index + 1))
    done
    [ ! -e "${CALLS}" ]
    assert_equal "$(find "${HOME}" -mindepth 1 -print)" ""
}

@test "diagram and realbox help advertise --list after validating all arguments" {
    local action option
    for action in diagram realbox; do
        run "${REAL_JUST}" --justfile "${REPO_ROOT}/justfile" verify "${action}" --help
        assert_success
        assert_output --partial '--list'
        for option in --help --list; do
            run "${REAL_JUST}" --justfile "${REPO_ROOT}/justfile" verify "${action}" "${option}" --bogus
            assert_failure 2
            assert_output --partial "${action}.sh: unknown option '--bogus' (see --help)"
        done
    done
    [ ! -e "${CALLS}" ]
}
