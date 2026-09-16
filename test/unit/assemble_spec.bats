#!/usr/bin/env bats
# test/unit/assemble_spec.bats - script/box/assemble.sh command construction
# and CLI (M2)
#
# Written test-first (RED) before the wrapper exists, then the wrapper is
# implemented to pass (GREEN).
#
# Contract under test:
#   - In dry-run mode (WORKTOOL_DRY_RUN=1 or --dry-run) the wrapper prints the
#     EXACT distrobox invocation to STDOUT and executes NOTHING.
#   - The default manifest is box/dev.ini, so the emitted command is
#     `distrobox assemble create --file box/dev.ini`.
#   - A `--file <path>` overrides the manifest and is reflected verbatim in the
#     emitted command.
#   - An invalid manifest fails before any command is emitted.
#   - The wrapper owns its CLI: `--help` / `-h` print usage and exit 0;
#     an unknown option is refused with `assemble.sh: unknown option '<x>'
#     (see --help)` on stderr, exit 2, nothing on stdout, and distrobox is
#     never called (the justfile in front of it validates nothing).

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    ASSEMBLE="${REPO_ROOT}/script/box/assemble.sh"
    TMP="${BATS_TEST_TMPDIR}"
    VALID="${TMP}/valid.ini"
    printf '[dev]\nimage=ubuntu:26.04\nadditional_packages="ripgrep fzf"\n' \
        >"${VALID}"

    # A poisoned `distrobox` on PATH: if dry-run ever executes it, the marker
    # file appears and the "does not execute" assertions catch it.
    MARKER="${TMP}/executed"
    MOCKBIN="${TMP}/bin"
    mkdir -p "${MOCKBIN}"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'touch "%s"\n' "${MARKER}"
    } >"${MOCKBIN}/distrobox"
    chmod +x "${MOCKBIN}/distrobox"
    PATH="${MOCKBIN}:${PATH}"
}

# --- dry-run via env var -----------------------------------------------------

@test "WORKTOOL_DRY_RUN=1 prints the distrobox command and executes nothing" {
    run env WORKTOOL_DRY_RUN=1 "${ASSEMBLE}" --file "${VALID}"
    assert_success
    assert_output "distrobox assemble create --file ${VALID}"
    assert [ ! -f "${MARKER}" ]
}

# --- dry-run via flag --------------------------------------------------------

@test "--dry-run flag prints the distrobox command and executes nothing" {
    run "${ASSEMBLE}" --dry-run --file "${VALID}"
    assert_success
    assert_output "distrobox assemble create --file ${VALID}"
    assert [ ! -f "${MARKER}" ]
}

# --- default manifest --------------------------------------------------------

@test "dry-run with the default manifest emits box/dev.ini" {
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}" --dry-run
    assert_success
    assert_output "distrobox assemble create --file box/dev.ini"
}

# --- validation fails fast ---------------------------------------------------

@test "dry-run on an invalid manifest fails and emits no command" {
    printf '[dev]\n' >"${TMP}/noimg.ini"
    run "${ASSEMBLE}" --dry-run --file "${TMP}/noimg.ini"
    assert_failure
    refute_output --partial "distrobox assemble create"
    assert_output --partial "missing required key 'image'"
}

# --- consistent resolved path (run from OUTSIDE the repo root) ----------------

@test "dry-run from outside the repo emits the resolved absolute manifest path" {
    # Run from a directory that is NOT the repo root, so the relative default
    # `box/dev.ini` only resolves against REPO_ROOT. The emitted command must
    # carry that same resolved absolute path (not the bare relative string).
    cd "${TMP}"
    run "${ASSEMBLE}" --dry-run
    assert_success
    assert_output "distrobox assemble create --file ${REPO_ROOT}/box/dev.ini"
}

# --- faithfully re-runnable dry-run (per-argument shell escaping) -------------

@test "dry-run escapes a path with spaces and metachars into one argument" {
    local _dir="${TMP}/we ird;dir\$(x)"
    mkdir -p "${_dir}"
    local _mani="${_dir}/dev.ini"
    printf '[dev]\nimage=ubuntu:26.04\n' >"${_mani}"

    run "${ASSEMBLE}" --dry-run --file "${_mani}"
    assert_success

    # The emitted line must round-trip: re-parsed by the shell it yields the
    # original manifest path as a SINGLE argument (position 5).
    eval "set -- ${output}"
    assert_equal "$#" 5
    assert_equal "$5" "${_mani}"
}

# --- the wrapper owns its CLI: --help and unknown options ---------------------

@test "--help exits 0, names --dry-run / --file / --help, and executes nothing" {
    run "${ASSEMBLE}" --help
    assert_success
    assert_output --partial "--dry-run"
    assert_output --partial "--file"
    assert_output --partial "--help"
    # No dry-run command line was emitted (that would be a bare line).
    refute_line --regexp '^distrobox assemble create '
    assert [ ! -f "${MARKER}" ]
}

@test "-h is the same as --help" {
    run "${ASSEMBLE}" --help
    local _long="${output}"
    run "${ASSEMBLE}" -h
    assert_success
    assert_output "${_long}"
}

@test "an unknown option exits 2 with the documented message on stderr, nothing on stdout, and executes nothing" {
    local _out="${TMP}/out" _err="${TMP}/err"
    run bash -c '"$1" --bogus >"$2" 2>"$3"' _ "${ASSEMBLE}" "${_out}" "${_err}"
    assert_failure 2
    run cat "${_out}"
    assert_output ""
    run cat "${_err}"
    assert_output "assemble.sh: unknown option '--bogus' (see --help)"
    assert [ ! -f "${MARKER}" ]
}

@test "an unknown option is refused even when combined with --help: exit 2 and no usage" {
    run "${ASSEMBLE}" --help --bogus
    assert_failure 2
    assert_output "assemble.sh: unknown option '--bogus' (see --help)"
    refute_output --partial "Usage:"
}

@test "an unknown option is refused even when combined with --dry-run: no command is emitted" {
    run "${ASSEMBLE}" --dry-run --bogus --file "${VALID}"
    assert_failure 2
    assert_output "assemble.sh: unknown option '--bogus' (see --help)"
}
