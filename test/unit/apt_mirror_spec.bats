#!/usr/bin/env bats
# test/unit/apt_mirror_spec.bats - script/test/apt-mirror.sh (issue #843)
#
# WHAT THIS PROVES
#   CI's Ubuntu package source is one knob: given a mirror, the script points
#   EVERY `URIs:` line of an Ubuntu deb822 sources file (the archive pockets
#   and the security pocket alike) at that one mirror and turns on apt's
#   retries; given no mirror it changes nothing, so a local build or run is
#   byte-for-byte what it was. A sources file it cannot rewrite is a failure,
#   never a silent fall back to the default mirror, and a mirror that is not
#   a plain http(s) URL is refused before anything is written (it ends up in
#   a Dockerfile line). The two Ubuntu test images run it before their first
#   `apt-get update`, from the one ARG the workflow sets.
#
# HOW
#   The script is run with --root against a fake root holding the
#   ubuntu:26.04 sources file; nothing outside BATS_TEST_TMPDIR is touched.

load "${BATS_TEST_DIRNAME}/../helper/common"

MIRROR="http://azure.archive.ubuntu.com/ubuntu/"

setup() {
    SCRIPT="${REPO_ROOT}/script/test/apt-mirror.sh"
    ROOT="${BATS_TEST_TMPDIR}/root"
    SOURCES="${ROOT}/etc/apt/sources.list.d/ubuntu.sources"
    CONF="${ROOT}/etc/apt/apt.conf.d/80worktool-ci"
    mkdir -p "${ROOT}/etc/apt/sources.list.d" "${ROOT}/etc/apt/apt.conf.d"
    # The ubuntu:26.04 file: archive pockets and security on two hosts.
    cat >"${SOURCES}" <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: resolute resolute-updates resolute-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: resolute-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    cp "${SOURCES}" "${BATS_TEST_TMPDIR}/orig.sources"
}

@test "a mirror replaces every URIs line, archive and security alike, and keeps the rest" {
    run bash "${SCRIPT}" --root "${ROOT}" "${MIRROR}"
    assert_success
    run grep -c "^URIs: ${MIRROR}\$" "${SOURCES}"
    assert_output 2
    run grep -E '^URIs:' "${SOURCES}"
    refute_line 'URIs: http://archive.ubuntu.com/ubuntu/'
    refute_line 'URIs: http://security.ubuntu.com/ubuntu/'
    # Only the URIs lines changed.
    run diff <(grep -v '^URIs:' "${BATS_TEST_TMPDIR}/orig.sources") <(grep -v '^URIs:' "${SOURCES}")
    assert_success
}

@test "a mirror turns on apt retries" {
    run bash "${SCRIPT}" --root "${ROOT}" "${MIRROR}"
    assert_success
    run cat "${CONF}"
    assert_line --regexp '^Acquire::Retries "[1-9][0-9]*";$'
}

@test "no mirror (or an empty one) changes nothing" {
    run bash "${SCRIPT}" --root "${ROOT}"
    assert_success
    run bash "${SCRIPT}" --root "${ROOT}" ""
    assert_success
    run cmp "${BATS_TEST_TMPDIR}/orig.sources" "${SOURCES}"
    assert_success
    assert [ ! -e "${CONF}" ]
}

@test "a missing sources file fails instead of silently keeping the default mirror" {
    rm "${SOURCES}"
    run bash "${SCRIPT}" --root "${ROOT}" "${MIRROR}"
    assert_failure 1
    assert_output --partial 'ubuntu.sources'
}

@test "a sources file without a URIs line fails" {
    grep -v '^URIs:' "${BATS_TEST_TMPDIR}/orig.sources" >"${SOURCES}"
    run bash "${SCRIPT}" --root "${ROOT}" "${MIRROR}"
    assert_failure 1
}

@test "a mirror that is not a plain http(s) URL is refused (exit 2) before anything is written" {
    local _bad
    for _bad in "ftp://example.org/ubuntu/" "http://a b/" "http://x/'y" "http://x/|y" "archive.ubuntu.com"; do
        run bash "${SCRIPT}" --root "${ROOT}" "${_bad}"
        assert_failure 2
        run cmp "${BATS_TEST_TMPDIR}/orig.sources" "${SOURCES}"
        assert_success
    done
}

@test "--check validates a mirror without touching anything" {
    run bash "${SCRIPT}" --check "${MIRROR}"
    assert_success
    run bash "${SCRIPT}" --check "http://x/'y"
    assert_failure 2
}

@test "--help exits 0 and an unknown option exits 2 with the standard message" {
    run bash "${SCRIPT}" --help
    assert_success
    run bash "${SCRIPT}" --bogus
    assert_failure 2
    assert_output "apt-mirror.sh: unknown option '--bogus' (see --help)"
}

@test "apt-mirror.sh runs under set -euo pipefail" {
    run grep -c '^set -euo pipefail$' "${SCRIPT}"
    assert_output 1
}

@test "both Ubuntu test images take APT_MIRROR (empty by default) and apply it before their first apt-get update" {
    local _df _first_update _mirror_line
    for _df in dockerfile/Dockerfile.ghostty dockerfile/Dockerfile.system-real; do
        run grep -E '^ARG APT_MIRROR=$' "${REPO_ROOT}/${_df}"
        assert_success "${_df} must declare ARG APT_MIRROR="
        run grep -F 'RUN --mount=type=bind,source=script/test/apt-mirror.sh,target=/tmp/apt-mirror.sh' "${REPO_ROOT}/${_df}"
        assert_success
        _mirror_line="$(grep -nF "bash /tmp/apt-mirror.sh \"\${APT_MIRROR}\"" "${REPO_ROOT}/${_df}" | head -n 1 | cut -d: -f1)"
        _first_update="$(grep -n 'apt-get update' "${REPO_ROOT}/${_df}" | head -n 1 | cut -d: -f1)"
        assert [ -n "${_mirror_line}" ]
        assert [ -n "${_first_update}" ]
        assert [ "${_mirror_line}" -le "${_first_update}" ]
    done
}
