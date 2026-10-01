#!/usr/bin/env bats
# test/unit/test_changed_spec.bats - changed-file test selection (issue #299)

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    TEMP_REPO="${BATS_TEST_TMPDIR}/repo"
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    export FAKE_DOCKER_CALLS="${BATS_TEST_TMPDIR}/docker.calls"
    mkdir -p "${TEMP_REPO}/script/test" "${TEMP_REPO}/test/unit" "${FAKE_BIN}"
    cp "${REPO_ROOT}/script/test/test.sh" "${TEMP_REPO}/script/test/test.sh"
    chmod +x "${TEMP_REPO}/script/test/test.sh"
    cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"${FAKE_DOCKER_CALLS}"
EOF
    chmod +x "${FAKE_BIN}/docker"
    export PATH="${FAKE_BIN}:${PATH}"
    export TEST_IMAGE_PREBUILT=1
    git -C "${TEMP_REPO}" init -q
    git -C "${TEMP_REPO}" config user.name Test
    git -C "${TEMP_REPO}" config user.email test@example.invalid
}

_commit_baseline() {
    git -C "${TEMP_REPO}" add .
    git -C "${TEMP_REPO}" commit -qm baseline
    git -C "${TEMP_REPO}" branch -M main
}

_dispatched() {
    sed -nE \
        -e 's/^docker run .* (--ci-[a-z-]+)( .*)?$/\1\2/p' \
        -e 's/^docker run .*(system-real-entry\.sh)$/\1/p' \
        "${FAKE_DOCKER_CALLS}"
}

@test "test.sh --changed runs a changed spec itself after lint" {
    printf '@test "example" { true; }\n' >"${TEMP_REPO}/test/unit/example_spec.bats"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/test/unit/example_spec.bats"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' \
        --ci-lint '--ci-unit test/unit/example_spec.bats')"
}

@test "test.sh --changed maps a changed library to its spec" {
    mkdir -p "${TEMP_REPO}/lib"
    printf '# log library\n' >"${TEMP_REPO}/lib/log.sh"
    printf '@test "log" { true; }\n' >"${TEMP_REPO}/test/unit/log_spec.bats"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/lib/log.sh"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' \
        --ci-lint '--ci-unit test/unit/log_spec.bats')"
}

@test "test.sh --changed fails open to the whole tier for an unmapped library" {
    mkdir -p "${TEMP_REPO}/lib"
    printf '# library\n' >"${TEMP_REPO}/lib/unmapped.sh"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/lib/unmapped.sh"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' --ci-lint --ci-unit)"
}

@test "test.sh --changed runs every affected tier for test infrastructure" {
    mkdir -p "${TEMP_REPO}/test/helper"
    printf '# helper\n' >"${TEMP_REPO}/test/helper/common.bash"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/test/helper/common.bash"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' \
        --ci-lint --ci-unit --ci-matrix --ci-integration \
        --ci-integration-ghostty --ci-system --ci-acceptance \
        system-real-entry.sh)"
}
