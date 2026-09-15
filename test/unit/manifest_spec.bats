#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/manifest_spec.bats - lib/manifest.sh box-manifest helpers (M2)
#
# Written test-first (RED) before lib/manifest.sh exists, then the library is
# implemented to pass (GREEN).
#
# Contract under test (worktool box manifest = a distrobox-assemble .ini file):
#   - manifest_name  <file>  -> prints the first [section] header's inner name
#   - manifest_image <file>  -> prints the first `image=` value (unquoted)
#   - manifest_validate <file>:
#       * returns 0 for a manifest that has a section name AND a non-empty image
#       * returns non-zero with a clear stderr message when the file is
#         missing, has no section name, or has no (or an empty) image key
#
# Validation diagnostics go to stderr via lib/log.sh; bats' `run` merges
# stdout+stderr into $output, so --partial assertions match the message.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    TMP="${BATS_TEST_TMPDIR}"
    # shellcheck source=../../lib/manifest.sh
    source "${LIB_DIR}/manifest.sh"
}

# --- manifest_name -----------------------------------------------------------

@test "manifest_name returns the section header name" {
    printf '[dev]\nimage=ubuntu:26.04\n' >"${TMP}/ok.ini"
    run manifest_name "${TMP}/ok.ini"
    assert_success
    assert_output "dev"
}

# --- manifest_image ----------------------------------------------------------

@test "manifest_image returns the image value" {
    printf '[dev]\nimage=ubuntu:26.04\n' >"${TMP}/ok.ini"
    run manifest_image "${TMP}/ok.ini"
    assert_success
    assert_output "ubuntu:26.04"
}

# --- manifest_validate: happy path -------------------------------------------

@test "valid manifest (section + image) passes validation" {
    printf '[dev]\nimage=ubuntu:26.04\nadditional_packages="ripgrep fzf"\n' \
        >"${TMP}/ok.ini"
    run manifest_validate "${TMP}/ok.ini"
    assert_success
}

# --- manifest_validate: failure modes ----------------------------------------

@test "manifest missing image fails with a clear message" {
    printf '[dev]\nadditional_packages="ripgrep fzf"\n' >"${TMP}/noimg.ini"
    run manifest_validate "${TMP}/noimg.ini"
    assert_failure
    assert_output --partial "missing required key 'image'"
}

@test "manifest with an empty image value counts as missing image" {
    printf '[dev]\nimage=\n' >"${TMP}/emptyimg.ini"
    run manifest_validate "${TMP}/emptyimg.ini"
    assert_failure
    assert_output --partial "missing required key 'image'"
}

@test "manifest missing the section name fails with a clear message" {
    printf 'image=ubuntu:26.04\n' >"${TMP}/noname.ini"
    run manifest_validate "${TMP}/noname.ini"
    assert_failure
    assert_output --partial "missing box name"
}

@test "a missing manifest file fails with a not-found message" {
    run manifest_validate "${TMP}/does-not-exist.ini"
    assert_failure
    assert_output --partial "manifest not found"
}
