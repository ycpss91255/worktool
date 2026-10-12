#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    REAL_JUST="$(command -v just)"
    CALLS="${BATS_TEST_TMPDIR}/calls"
    export CALLS
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
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
