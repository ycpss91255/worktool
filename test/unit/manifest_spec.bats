#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/manifest_spec.bats - lib/manifest.sh box-manifest helpers (M2)
#
# Written test-first (RED) before lib/manifest.sh exists, then the library is
# implemented to pass (GREEN).
#
# Contract under test (worktool box manifest = a distrobox-assemble .ini file):
#   - manifest_name  <file>  -> prints the first [section] header's inner name
#   - manifest_image <file>  -> prints the first `image=` value (one matched
#                               outer pair of quotes stripped); returns 2 on
#                               an unbalanced outer quote
#   - manifest_home  <file>  -> the box HOME from the section's `home=` (issue
#                               #199): 1 when none, 2 when unresolvable
#   - manifest_validate <file>:
#       * returns 0 for a manifest that has a section name AND a non-empty image
#       * returns non-zero with a clear stderr message when the file is
#         missing, has no section name, has no (or an empty) image key, or
#         has an image value with an unbalanced outer quote
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

# --- whitespace-only values --------------------------------------------------

@test "manifest_name rejects a whitespace-only section header" {
    printf '[   ]\nimage=ubuntu:26.04\n' >"${TMP}/wsname.ini"
    run manifest_name "${TMP}/wsname.ini"
    assert_failure
}

@test "a whitespace-only section name fails validation with a clear message" {
    printf '[   ]\nimage=ubuntu:26.04\n' >"${TMP}/wsname.ini"
    run manifest_validate "${TMP}/wsname.ini"
    assert_failure
    assert_output --partial "missing box name"
}

@test "manifest_image treats a quoted whitespace-only value as empty" {
    printf '[dev]\nimage="   "\n' >"${TMP}/wsimg.ini"
    run manifest_image "${TMP}/wsimg.ini"
    assert_success
    assert_output ""
}

@test "a quoted whitespace-only image fails validation as missing image" {
    printf '[dev]\nimage="   "\n' >"${TMP}/wsimg.ini"
    run manifest_validate "${TMP}/wsimg.ini"
    assert_failure
    assert_output --partial "missing required key 'image'"
}

@test "manifest_image treats a space-then-quoted whitespace value as empty" {
    printf '[dev]\nimage= "   "\n' >"${TMP}/wsimg2.ini"
    run manifest_image "${TMP}/wsimg2.ini"
    assert_success
    assert_output ""
}

@test "a space-then-quoted whitespace image fails validation as missing image" {
    printf '[dev]\nimage= "   "\n' >"${TMP}/wsimg2.ini"
    run manifest_validate "${TMP}/wsimg2.ini"
    assert_failure
    assert_output --partial "missing required key 'image'"
}

# --- single-quoted values ----------------------------------------------------
# distrobox-assemble writes each `key=value` line into a tmpfile and sources it
# as a SHELL ASSIGNMENT, so single quotes are valid quoting there: image=''
# and image='   ' are blank images exactly like their double-quoted twins and
# must be rejected the same way, not read as a non-empty "'   '" string.
#
# Quote rule under test (see _manifest_unquote): after trimming the whole
# value, if the FIRST or LAST character is a quote (" or ') the value must be
# a MATCHED pair - the same quote character at both ends and length >= 2 -
# and exactly that one outer pair is stripped (then trimmed again). Any other
# leading/trailing quote - a lone ' or ", a mismatched pair ('..."), a
# one-sided quote ("... or ...") - is MALFORMED: upstream sources the value
# as a shell assignment, where that is a syntax error, so worktool's
# pre-flight rejects it with a distinct, clear "unbalanced quote" message
# instead of letting distrobox emit a shell error. Quotes strictly inside
# the value are left alone.

@test "manifest_image treats a single-quoted empty value as empty" {
    printf "[dev]\nimage=''\n" >"${TMP}/sqempty.ini"
    run manifest_image "${TMP}/sqempty.ini"
    assert_success
    assert_output ""
}

@test "a single-quoted empty image fails validation as missing image" {
    printf "[dev]\nimage=''\n" >"${TMP}/sqempty.ini"
    run manifest_validate "${TMP}/sqempty.ini"
    assert_failure
    assert_output --partial "missing required key 'image'"
}

@test "manifest_image treats a single-quoted whitespace-only value as empty" {
    printf "[dev]\nimage='   '\n" >"${TMP}/sqws.ini"
    run manifest_image "${TMP}/sqws.ini"
    assert_success
    assert_output ""
}

@test "a single-quoted whitespace-only image fails validation as missing image" {
    printf "[dev]\nimage='   '\n" >"${TMP}/sqws.ini"
    run manifest_validate "${TMP}/sqws.ini"
    assert_failure
    assert_output --partial "missing required key 'image'"
}

@test "manifest_image treats a space-then-single-quoted whitespace value as empty" {
    printf "[dev]\nimage= '   '\n" >"${TMP}/sqws2.ini"
    run manifest_image "${TMP}/sqws2.ini"
    assert_success
    assert_output ""
}

@test "a space-then-single-quoted whitespace image fails validation as missing image" {
    printf "[dev]\nimage= '   '\n" >"${TMP}/sqws2.ini"
    run manifest_validate "${TMP}/sqws2.ini"
    assert_failure
    assert_output --partial "missing required key 'image'"
}

# --- legal quoting: the three forms all yield the bare value -----------------

@test "manifest_image unquotes a single-quoted real image value" {
    printf "[dev]\nimage='ubuntu:26.04'\n" >"${TMP}/sqok.ini"
    run manifest_image "${TMP}/sqok.ini"
    assert_success
    assert_output "ubuntu:26.04"
    run manifest_validate "${TMP}/sqok.ini"
    assert_success
}

@test "manifest_image unquotes a double-quoted real image value" {
    printf '[dev]\nimage="ubuntu:26.04"\n' >"${TMP}/dqok.ini"
    run manifest_image "${TMP}/dqok.ini"
    assert_success
    assert_output "ubuntu:26.04"
    run manifest_validate "${TMP}/dqok.ini"
    assert_success
}

@test "an unquoted image value is returned as-is and passes validation" {
    printf '[dev]\nimage=ubuntu:26.04\n' >"${TMP}/bareok.ini"
    run manifest_image "${TMP}/bareok.ini"
    assert_success
    assert_output "ubuntu:26.04"
    run manifest_validate "${TMP}/bareok.ini"
    assert_success
}

@test "quotes strictly inside the value are left alone" {
    # Neither end is a quote, so the quote rule does not apply at all: the
    # value is kept verbatim (worktool is a pre-flight, not a shell parser).
    printf "[dev]\nimage=ubuntu:26.04'x\"y\n" >"${TMP}/inner.ini"
    run manifest_image "${TMP}/inner.ini"
    assert_success
    assert_output "ubuntu:26.04'x\"y"
    run manifest_validate "${TMP}/inner.ini"
    assert_success
}

# --- malformed quoting: unbalanced outer quotes are rejected -----------------
# Each of these is a shell syntax error once distrobox-assemble sources the
# value, so worktool must catch it BEFORE distrobox is called, with a message
# distinct from "missing image" (the value is not blank - it is malformed).

@test "a lone single quote is an unbalanced quote and fails validation" {
    printf "[dev]\nimage='\n" >"${TMP}/lonesq.ini"
    run manifest_image "${TMP}/lonesq.ini"
    assert_failure 2
    run manifest_validate "${TMP}/lonesq.ini"
    assert_failure 1
    assert_output --partial "unbalanced quote"
    refute_output --partial "missing required key 'image'"
}

@test "a lone double quote is an unbalanced quote and fails validation" {
    printf '[dev]\nimage="\n' >"${TMP}/lonedq.ini"
    run manifest_image "${TMP}/lonedq.ini"
    assert_failure 2
    run manifest_validate "${TMP}/lonedq.ini"
    assert_failure 1
    assert_output --partial "unbalanced quote"
    refute_output --partial "missing required key 'image'"
}

@test "a space-then-lone quote is still an unbalanced quote" {
    # Trimming happens first, so `image= '` is the same lone quote.
    printf "[dev]\nimage= '\n" >"${TMP}/lonesq2.ini"
    run manifest_validate "${TMP}/lonesq2.ini"
    assert_failure 1
    assert_output --partial "unbalanced quote"
}

@test "mismatched outer quotes are an unbalanced quote and fail validation" {
    # Opening ' but closing ": not a matched pair.
    printf "[dev]\nimage='ubuntu:26.04\"\n" >"${TMP}/mixed.ini"
    run manifest_image "${TMP}/mixed.ini"
    assert_failure 2
    run manifest_validate "${TMP}/mixed.ini"
    assert_failure 1
    assert_output --partial "unbalanced quote"
    # The offending value is named so the user can see what to fix.
    assert_output --partial "'ubuntu:26.04\""
}

@test "a one-sided leading quote is an unbalanced quote and fails validation" {
    printf '[dev]\nimage="ubuntu:26.04\n' >"${TMP}/lead.ini"
    run manifest_image "${TMP}/lead.ini"
    assert_failure 2
    run manifest_validate "${TMP}/lead.ini"
    assert_failure 1
    assert_output --partial "unbalanced quote"
    assert_output --partial '"ubuntu:26.04'
}

@test "a one-sided trailing quote is an unbalanced quote and fails validation" {
    printf '[dev]\nimage=ubuntu:26.04"\n' >"${TMP}/trail.ini"
    run manifest_image "${TMP}/trail.ini"
    assert_failure 2
    run manifest_validate "${TMP}/trail.ini"
    assert_failure 1
    assert_output --partial "unbalanced quote"
    assert_output --partial 'ubuntu:26.04"'
}

@test "a one-sided trailing single quote is an unbalanced quote too" {
    printf "[dev]\nimage=ubuntu:26.04'\n" >"${TMP}/trailsq.ini"
    run manifest_validate "${TMP}/trailsq.ini"
    assert_failure 1
    assert_output --partial "unbalanced quote"
}

# --- section-membership validation -------------------------------------------

@test "an image before any section header is rejected as missing" {
    printf 'image=ubuntu:26.04\n[dev]\n' >"${TMP}/preimg.ini"
    run manifest_validate "${TMP}/preimg.ini"
    assert_failure
    assert_output --partial "missing required key 'image'"
}

@test "an image in a different section than the box is rejected (multi-section)" {
    printf '[dev]\n[other]\nimage=ubuntu:26.04\n' >"${TMP}/otherimg.ini"
    run manifest_validate "${TMP}/otherimg.ini"
    assert_failure
    assert_output --partial "multiple sections"
}

@test "a multi-section manifest is rejected (single box only)" {
    printf '[dev]\nimage=ubuntu:26.04\n[other]\nimage=debian:13\n' \
        >"${TMP}/multi.ini"
    run manifest_validate "${TMP}/multi.ini"
    assert_failure
    assert_output --partial "multiple sections"
}

# --- manifest_home (issue #199, ADR 0002 decision 1) ---------------------------
# The box HOME is the manifest's own `home=` key (distrobox-assemble's native
# key, passed to `distrobox create --home`). No `home=` means the box shares
# the host HOME. The value is resolved the way the shell distrobox-assemble
# sources it would: an unquoted leading `~`, `$HOME` or `${HOME}` expands;
# anything worktool cannot predict is refused (return 2) instead of guessed.

@test "manifest_home: no home= line returns 1 (the box shares the host HOME)" {
    printf '[dev]\nimage=ubuntu:26.04\n' >"${TMP}/nohome.ini"
    run manifest_home "${TMP}/nohome.ini"
    assert_failure 1
    assert_output ""
}

@test "manifest_home: an absolute home= is printed as-is" {
    printf '[dev]\nimage=ubuntu:26.04\nhome=/srv/dev-home\n' >"${TMP}/abs.ini"
    run manifest_home "${TMP}/abs.ini"
    assert_success
    assert_output "/srv/dev-home"
    printf '[dev]\nimage=ubuntu:26.04\nhome="/srv/dev home"\n' >"${TMP}/q.ini"
    run manifest_home "${TMP}/q.ini"
    assert_success
    assert_output "/srv/dev home"
}

@test "manifest_home: an unquoted leading ~, \$HOME or \${HOME} expands to HOME" {
    local _v _t='~'
    for _v in "${_t}/dev-box" "\$HOME/dev-box" "\${HOME}/dev-box"; do
        printf '[dev]\nimage=ubuntu:26.04\nhome=%s\n' "${_v}" >"${TMP}/tilde.ini"
        run manifest_home "${TMP}/tilde.ini"
        assert_success
        assert_output "${HOME}/dev-box"
    done
}

@test "manifest_home: home= outside the box section is not the box's" {
    printf 'home=/srv/pre\n[dev]\nimage=ubuntu:26.04\n' >"${TMP}/pre.ini"
    run manifest_home "${TMP}/pre.ini"
    assert_failure 1
}

@test "manifest_home: a value worktool cannot resolve safely returns 2" {
    local _v
    for _v in 'relative/dir' '.' '/srv/../etc' '"~/dev-box"' "/srv/\$USER" '' '"/srv'; do
        printf '[dev]\nimage=ubuntu:26.04\nhome=%s\n' "${_v}" >"${TMP}/bad.ini"
        run manifest_home "${TMP}/bad.ini"
        assert_failure 2
    done
}

@test "manifest_validate rejects a home= it cannot resolve, before distrobox runs" {
    printf '[dev]\nimage=ubuntu:26.04\nhome=relative/dir\n' >"${TMP}/bad.ini"
    run manifest_validate "${TMP}/bad.ini"
    assert_failure
    assert_output --partial "home"
    assert_output --partial "relative/dir"
    printf '[dev]\nimage=ubuntu:26.04\nhome=~/dev-box\n' >"${TMP}/ok.ini"
    run manifest_validate "${TMP}/ok.ini"
    assert_success
}
