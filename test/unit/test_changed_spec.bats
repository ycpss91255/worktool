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
    sed -nE 's/^docker run .* (--ci-[a-z-]+)( .*)?$/\1\2/p' \
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
