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
    git -C "${TEMP_REPO}" update-ref refs/remotes/origin/main HEAD
    printf '\n# changed\n' >>"${TEMP_REPO}/test/unit/example_spec.bats"
    git -C "${TEMP_REPO}" add test/unit/example_spec.bats
    git -C "${TEMP_REPO}" commit -qm changed

    run bash -c 'cd "$1" && ./script/test/test.sh --changed' _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' \
        --ci-lint '--ci-unit test/unit/example_spec.bats')"
}

@test "test.sh --changed runs a changed matrix spec itself after lint" {
    mkdir -p "${TEMP_REPO}/test/matrix"
    printf '@test "matrix" { true; }\n' \
        >"${TEMP_REPO}/test/matrix/example_spec.bats"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/test/matrix/example_spec.bats"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' \
        --ci-lint '--ci-matrix test/matrix/example_spec.bats')"
}

@test "test.sh --changed runs a changed matrix spec during fallback" {
    mkdir -p "${TEMP_REPO}/test/helper" "${TEMP_REPO}/test/matrix"
    printf '# helper\n' >"${TEMP_REPO}/test/helper/common.bash"
    printf '@test "matrix" { true; }\n' \
        >"${TEMP_REPO}/test/matrix/example_spec.bats"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/test/helper/common.bash"
    printf '\n# changed\n' >>"${TEMP_REPO}/test/matrix/example_spec.bats"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' \
        --ci-lint --ci-unit \
        '--ci-matrix test/matrix/example_spec.bats')"
}

@test "test.sh --changed skips a deleted spec" {
    printf '@test "deleted" { true; }\n' >"${TEMP_REPO}/test/unit/deleted_spec.bats"
    _commit_baseline
    git -C "${TEMP_REPO}" rm -q test/unit/deleted_spec.bats

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" --ci-lint
}

@test "test.sh --changed leaves a changed integration spec to CI" {
    mkdir -p "${TEMP_REPO}/test/integration"
    printf '@test "integration" { true; }\n' \
        >"${TEMP_REPO}/test/integration/example_spec.bats"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/test/integration/example_spec.bats"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" --ci-lint
    assert_output --partial "此改動由 CI 的 integration 驗證"
}

@test "test.sh --changed leaves a changed system spec to CI" {
    mkdir -p "${TEMP_REPO}/test/system"
    printf '@test "system" { true; }\n' \
        >"${TEMP_REPO}/test/system/example_spec.bats"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/test/system/example_spec.bats"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" --ci-lint
    assert_output --partial "此改動由 CI 的 system 驗證"
}

@test "test.sh --changed leaves a changed acceptance spec to CI" {
    mkdir -p "${TEMP_REPO}/test/acceptance"
    printf '@test "acceptance" { true; }\n' \
        >"${TEMP_REPO}/test/acceptance/example_spec.bats"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/test/acceptance/example_spec.bats"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" --ci-lint
    assert_output --partial "此改動由 CI 的 acceptance 驗證"
}

@test "test.sh --changed leaves the real-engine spec to CI" {
    mkdir -p "${TEMP_REPO}/test/system"
    printf '@test "real engine" { true; }\n' \
        >"${TEMP_REPO}/test/system/real_engine_spec.bats"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/test/system/real_engine_spec.bats"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" --ci-lint
    assert_output --partial "此改動由 CI 的 system-real 驗證"
}

@test "test.sh --changed leaves Dockerfile.ghostty verification to CI" {
    mkdir -p "${TEMP_REPO}/dockerfile"
    printf 'FROM scratch\n' >"${TEMP_REPO}/dockerfile/Dockerfile.ghostty"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/dockerfile/Dockerfile.ghostty"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" --ci-lint
    assert_output --partial "此改動由 CI 的 integration 驗證"
}

@test "test.sh --changed leaves Dockerfile.system-real verification to CI" {
    mkdir -p "${TEMP_REPO}/dockerfile"
    printf 'FROM scratch\n' >"${TEMP_REPO}/dockerfile/Dockerfile.system-real"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/dockerfile/Dockerfile.system-real"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" --ci-lint
    assert_output --partial "此改動由 CI 的 system-real 驗證"
}

@test "test.sh --changed leaves the system-real entry verification to CI" {
    mkdir -p "${TEMP_REPO}/script/test"
    printf '# entry\n' >"${TEMP_REPO}/script/test/system-real-entry.sh"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/script/test/system-real-entry.sh"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" --ci-lint
    assert_output --partial "此改動由 CI 的 system-real 驗證"
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

@test "test.sh --changed maps a source file to specs across tiers" {
    mkdir -p "${TEMP_REPO}/script/box" "${TEMP_REPO}/test/integration"
    printf '# setup script\n' >"${TEMP_REPO}/script/box/setup.sh"
    printf '@test "unit setup" { true; }\n' \
        >"${TEMP_REPO}/test/unit/setup_spec.bats"
    printf '@test "integration setup" { true; }\n' \
        >"${TEMP_REPO}/test/integration/setup_spec.bats"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/script/box/setup.sh"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' \
        --ci-lint '--ci-unit test/unit/setup_spec.bats')"
    assert_output --partial "此改動由 CI 的 integration 驗證"
}

@test "test.sh --changed fails open when a mapped spec is missing" {
    mkdir -p "${TEMP_REPO}/lib"
    printf '# log library\n' >"${TEMP_REPO}/lib/log.sh"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/lib/log.sh"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' --ci-lint --ci-unit)"
}

@test "changed path map points only to existing specs" {
    run bash -c '
        source "$1/script/test/test.sh"
        missing=0
        while IFS="|" read -r _ spec; do
            if [[ ! -f "$1/$spec" ]]; then
                printf "missing mapped spec: %s\n" "$spec"
                missing=1
            fi
        done < <(_changed_path_map)
        exit "$missing"
    ' _ "${REPO_ROOT}"

    assert_success
}

@test "test.sh --changed fails open to the whole tier for an unmapped library" {
    _commit_baseline
    mkdir -p "${TEMP_REPO}/lib"
    printf '# library\n' >"${TEMP_REPO}/lib/unmapped.sh"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' --ci-lint --ci-unit)"
}

@test "test.sh --changed fails open only to unit for test infrastructure" {
    mkdir -p "${TEMP_REPO}/test/helper"
    printf '# helper\n' >"${TEMP_REPO}/test/helper/common.bash"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/test/helper/common.bash"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' --ci-lint --ci-unit)"
    for tier in matrix integration system system-real acceptance; do
        assert_output --partial "此改動由 CI 的 ${tier} 驗證"
    done
}

@test "test.sh --changed fails open when the base diff is unreadable" {
    _commit_baseline

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base missing-ref' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' --ci-lint --ci-unit)"
    for tier in matrix integration system system-real acceptance; do
        assert_output --partial "此改動由 CI 的 ${tier} 驗證"
    done
}

@test "test.sh --changed selects a mapped unit spec once in first-seen order" {
    mkdir -p "${TEMP_REPO}/lib"
    printf '# home library\n' >"${TEMP_REPO}/lib/home.sh"
    for spec in assemble setup status; do
        printf '@test "example" { true; }\n' \
            >"${TEMP_REPO}/test/unit/${spec}_spec.bats"
    done
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/lib/home.sh"
    printf '\n# changed\n' >>"${TEMP_REPO}/test/unit/setup_spec.bats"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' --ci-lint \
        '--ci-unit test/unit/assemble_spec.bats test/unit/setup_spec.bats test/unit/status_spec.bats')"
}

@test "test.sh --changed selects a mapped matrix spec once in first-seen order" {
    mkdir -p "${TEMP_REPO}/.agents/hook" "${TEMP_REPO}/test/matrix" \
        "${TEMP_REPO}/test/unit/hook"
    printf '# hook\n' >"${TEMP_REPO}/.agents/hook/enforce_local_test_scope.sh"
    printf '@test "unit" { true; }\n' \
        >"${TEMP_REPO}/test/unit/hook/enforce_local_test_scope_spec.bats"
    printf '@test "matrix" { true; }\n' \
        >"${TEMP_REPO}/test/matrix/enforce_local_test_scope_spec.bats"
    printf '@test "another" { true; }\n' >"${TEMP_REPO}/test/matrix/another_spec.bats"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/.agents/hook/enforce_local_test_scope.sh"
    printf '\n# changed\n' >>"${TEMP_REPO}/test/matrix/enforce_local_test_scope_spec.bats"
    printf '\n# changed\n' >>"${TEMP_REPO}/test/matrix/another_spec.bats"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' --ci-lint \
        '--ci-unit test/unit/hook/enforce_local_test_scope_spec.bats' \
        '--ci-matrix test/matrix/enforce_local_test_scope_spec.bats test/matrix/another_spec.bats')"
}

# Observe selection before CI-only tiers are deferred by the dispatcher.
_selected_changed_specs() {
    run bash -c '
        source "$1/script/test/test.sh"
        tier="$2"
        _run_changed_tiers() {
            local -n selected="_${tier}"
            printf "%s\n" "${selected[@]}"
        }
        if [[ "$2" == acceptance ]]; then
            _changed_path_map() {
                printf "%s\n" "lib/example.sh|test/acceptance/example_spec.bats"
            }
        fi
        main --changed --base main
    ' _ "${TEMP_REPO}" "$1"
}

@test "test.sh --changed selects a mapped integration spec once in first-seen order" {
    mkdir -p "${TEMP_REPO}/script/box" "${TEMP_REPO}/test/integration"
    printf '# setup\n' >"${TEMP_REPO}/script/box/setup.sh"
    printf '@test "unit" { true; }\n' >"${TEMP_REPO}/test/unit/setup_spec.bats"
    for spec in setup another; do
        printf '@test "example" { true; }\n' \
            >"${TEMP_REPO}/test/integration/${spec}_spec.bats"
    done
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/script/box/setup.sh"
    printf '\n# changed\n' >>"${TEMP_REPO}/test/integration/setup_spec.bats"
    printf '\n# changed\n' >>"${TEMP_REPO}/test/integration/another_spec.bats"

    _selected_changed_specs integration

    assert_success
    assert_equal "$output" "$(printf '%s\n' \
        test/integration/setup_spec.bats test/integration/another_spec.bats)"
}

@test "test.sh --changed selects a mapped system spec once in first-seen order" {
    mkdir -p "${TEMP_REPO}/script/box" "${TEMP_REPO}/test/integration" \
        "${TEMP_REPO}/test/system"
    printf '# assemble\n' >"${TEMP_REPO}/script/box/assemble.sh"
    printf '@test "unit" { true; }\n' >"${TEMP_REPO}/test/unit/assemble_spec.bats"
    printf '@test "integration" { true; }\n' \
        >"${TEMP_REPO}/test/integration/assemble_spec.bats"
    for spec in real_assemble another; do
        printf '@test "example" { true; }\n' \
            >"${TEMP_REPO}/test/system/${spec}_spec.bats"
    done
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/script/box/assemble.sh"
    printf '\n# changed\n' >>"${TEMP_REPO}/test/system/real_assemble_spec.bats"
    printf '\n# changed\n' >>"${TEMP_REPO}/test/system/another_spec.bats"

    _selected_changed_specs system

    assert_success
    assert_equal "$output" "$(printf '%s\n' \
        test/system/real_assemble_spec.bats test/system/another_spec.bats)"
}
