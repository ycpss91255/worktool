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

@test "changed documentation consistently leaves unknown impact verification to CI" {
    run just --justfile "${REPO_ROOT}/script/test/justfile.test" --list
    assert_success
    assert_line --regexp 'changed .*unknown impact.*CI'
    refute_output --partial 'fails open'

    run sed -n '/^| `just test changed /p' "${REPO_ROOT}/doc/structure.md"
    assert_success
    assert_output --regexp '無法判定.*交由 CI'
    refute_output --partial '完整 unit'

    run sed -n '/^6\. /p' "${REPO_ROOT}/doc/adr/0014-local-tests-changed-only.md"
    assert_success
    assert_output --regexp '無法判定.*交由 CI'
    assert_output --partial '#376'
    refute_output --partial 'fail open'
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
        --ci-lint \
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

@test "test.sh --changed leaves missing mapped specs to CI and names the source" {
    mkdir -p "${TEMP_REPO}/lib"
    printf '# log library\n' >"${TEMP_REPO}/lib/log.sh"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/lib/log.sh"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" --ci-lint
    assert_output --partial "此改動由 CI 的 unit 驗證"
    assert_output --partial "lib/log.sh"
    assert_output --partial "test/unit/log_spec.bats"
    assert_output --partial "對應 spec 不存在"
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

@test "test.sh --changed leaves unmapped files to CI and names each file" {
    _commit_baseline
    mkdir -p "${TEMP_REPO}/lib"
    printf '# library\n' >"${TEMP_REPO}/lib/unmapped.sh"
    mkdir -p "${TEMP_REPO}/doc/research"
    printf '# notes\n' >"${TEMP_REPO}/doc/research/notes.md"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" --ci-lint
    assert_output --partial "此改動由 CI 的 unit 驗證"
    assert_output --partial "lib/unmapped.sh"
    assert_output --partial "doc/research/notes.md"
    assert_output --partial "沒有對應 spec"
}

@test "test.sh --changed leaves test infrastructure to CI with filenames and reasons" {
    local -a _paths=(test/helper/common.bash script/test/test.sh
        dockerfile/Dockerfile.test Dockerfile justfile script/test/justfile.test)
    local _path
    for _path in "${_paths[@]}"; do
        mkdir -p "${TEMP_REPO}/$(dirname "${_path}")"
        touch "${TEMP_REPO}/${_path}"
    done
    printf '@test "example" { true; }\n' >"${TEMP_REPO}/test/unit/example_spec.bats"
    _commit_baseline
    for _path in "${_paths[@]}"; do
        printf '\n# changed\n' >>"${TEMP_REPO}/${_path}"
    done
    printf '\n# changed\n' >>"${TEMP_REPO}/test/unit/example_spec.bats"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' \
        --ci-lint '--ci-unit test/unit/example_spec.bats')"
    for tier in unit matrix integration system system-real acceptance; do
        assert_output --partial "此改動由 CI 的 ${tier} 驗證"
    done
    for _path in "${_paths[@]}"; do
        assert_output --partial "${_path}"
    done
    assert_output --partial "測試基礎設施變更"
}

@test "test.sh --changed leaves an unreadable base diff to CI" {
    _commit_baseline

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base missing-ref' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" --ci-lint
    assert_output --partial "changed-file diff unreadable; verification left to CI"
    refute_output --partial "running the unit tier"
    for tier in unit matrix integration system system-real acceptance; do
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

@test "test.sh --changed dispatches readiness evidence hook spec" {
    mkdir -p "${TEMP_REPO}/.agents/hook/lib" "${TEMP_REPO}/test/unit/hook"
    printf '# readiness policy\n' >"${TEMP_REPO}/.agents/hook/lib/ready_evidence.sh"
    printf '@test "readiness evidence" { true; }\n' \
        >"${TEMP_REPO}/test/unit/hook/enforce_milestone_ready_evidence_spec.bats"
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/.agents/hook/lib/ready_evidence.sh"

    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"

    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' \
        --ci-lint '--ci-unit test/unit/hook/enforce_milestone_ready_evidence_spec.bats')"
}

_document_change() {
    local _path="$1"
    shift
    mkdir -p "${TEMP_REPO}/$(dirname "${_path}")"
    printf '# document\n' >"${TEMP_REPO}/${_path}"
    local _spec
    for _spec in "$@"; do
        mkdir -p "${TEMP_REPO}/$(dirname "${_spec}")"
        printf '@test "guard" { true; }\n' >"${TEMP_REPO}/${_spec}"
    done
    _commit_baseline
    printf '\n# changed\n' >>"${TEMP_REPO}/${_path}"
    run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
        _ "${TEMP_REPO}"
    assert_success
    assert_equal "$(_dispatched)" "$(printf '%s\n' --ci-lint "--ci-unit $*")"
}

@test "test.sh --changed maps root documentation to existing documentation guards" {
    _document_change doc/structure.md test/unit/contract_spec.bats \
        test/unit/diagram_spec.bats test/unit/justfile_spec.bats test/unit/adr/0007_spec.bats
}

@test "test.sh --changed maps ADR documents to shared and individual guards" {
    local -a _specs=(test/unit/adr_spec.bats)
    local _number
    for _number in 0004 0005 0006 0007 0008 0009 0010 0011 0012 0013; do
        _specs+=("test/unit/adr/${_number}_spec.bats")
    done
    _document_change doc/adr/0004-invariant-user-content.md "${_specs[@]}"
}

@test "test.sh --changed maps the contract to its invariant index guards" {
    _document_change doc/contract.md test/unit/contract_spec.bats \
        test/unit/diagram_spec.bats test/unit/justfile_spec.bats \
        test/unit/adr/0004_spec.bats test/unit/adr/0007_spec.bats \
        test/unit/adr/0009_spec.bats
}

@test "test.sh --changed maps diagrams to the diagram guard" {
    _document_change doc/diagram/flow.drawio.svg test/unit/diagram_spec.bats
}

@test "test.sh --changed maps README to diagram and command documentation guards" {
    _document_change README.md test/unit/diagram_spec.bats test/unit/justfile_spec.bats
}

@test "test.sh --changed includes specialized guards for interface and workflow docs" {
    local _path
    local -a _extra
    for _path in doc/manifest.md doc/enter.md doc/design.md doc/workflow.md; do
        case "${_path}" in
            doc/manifest.md) _extra=(test/unit/bench_spec.bats test/unit/adr/0007_spec.bats) ;;
            doc/enter.md) _extra=(test/unit/adr/0007_spec.bats) ;;
            doc/design.md) _extra=(test/unit/adr/0008_spec.bats) ;;
            doc/workflow.md) _extra=(test/unit/workflow_spec.bats) ;;
        esac
        : >"${FAKE_DOCKER_CALLS}"
        _document_change "${_path}" test/unit/contract_spec.bats \
            test/unit/diagram_spec.bats test/unit/justfile_spec.bats "${_extra[@]}"
    done
}

@test "test.sh --changed names dedicated runner infrastructure left to CI" {
    local _path _tier
    for _path in dockerfile/Dockerfile.ghostty dockerfile/Dockerfile.system-real \
        script/test/system-real-entry.sh; do
        mkdir -p "${TEMP_REPO}/$(dirname "${_path}")"
        printf '# runner\n' >"${TEMP_REPO}/${_path}"
        _commit_baseline
        printf '\n# changed\n' >>"${TEMP_REPO}/${_path}"
        : >"${FAKE_DOCKER_CALLS}"
        run bash -c 'cd "$1" && ./script/test/test.sh --changed --base main' \
            _ "${TEMP_REPO}"
        assert_success
        assert_equal "$(_dispatched)" --ci-lint
        _tier=system-real
        [[ "${_path}" != dockerfile/Dockerfile.ghostty ]] || _tier=integration
        assert_output --partial "此改動由 CI 的 ${_tier} 驗證：${_path}"
        assert_output --partial "測試基礎設施變更"
    done
}
