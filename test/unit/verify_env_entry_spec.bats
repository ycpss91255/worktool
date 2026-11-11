#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"

@test "verify-env parses all options before help and rejects unknown options" {
    run just -f "${REPO_ROOT}/justfile" test verify-env --help --invalid
    assert_failure 2
    assert_output --partial "verify-env.sh: unknown option '--invalid' (see --help)"
    run just -f "${REPO_ROOT}/justfile" test verify-env --help
    assert_success
    assert_output --partial 'Usage: just test verify-env'
}

@test "verify-env forwards the selected APT mirror to the Ghostty build, including the empty default" {
    local bin="${BATS_TEST_TMPDIR}/bin" mirror
    mkdir -p "${bin}"
    cat >"${bin}/just" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat >"${bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == build && "$*" == *Dockerfile.ghostty* ]]; then
    printf '%s\n' "$@" >"${BUILD_ARGS}"
fi
EOF
    chmod +x "${bin}/just" "${bin}/docker"
    for mirror in 'http://mirror.example/ubuntu/' ''; do
        PATH="${bin}:${PATH}" BUILD_ARGS="${BATS_TEST_TMPDIR}/build-args" \
            WORKTOOL_APT_MIRROR="${mirror}" run "${REPO_ROOT}/script/test/verify-env.sh"
        assert_success
        run cat "${BATS_TEST_TMPDIR}/build-args"
        assert_success
        assert_line -- '--build-arg'
        assert_line "APT_MIRROR=${mirror}"
        assert_line 'dockerfile/Dockerfile.ghostty'
    done
}
