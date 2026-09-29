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
#   - Issue #198: `--home <path>` names the box HOME (default
#     ~/<box>-box, the box name from the manifest; a stored user choice in
#     ~/.config/worktool/config wins over the default). The resolved path
#     is logged as `[INFO] box home: <path> (default|user)` on stderr; the
#     dry-run STDOUT line is unchanged (the path travels to distrobox in
#     the environment, not in argv). A bad --home is a usage error (exit
#     2); a stored home that is not an absolute path, or a manifest that
#     sets distrobox's own `home=` key, is refused with exit 1.

load "${BATS_TEST_DIRNAME}/../helper/common"

# `run --separate-stderr` keeps the dry-run STDOUT contract exact while the
# box-home INFO line goes to stderr.
bats_require_minimum_version 1.5.0

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

    # Issue #198: a throwaway HOME (the default box home and the state file
    # derive from it) and no inherited distrobox home overrides.
    HOME="${TMP}/home"
    export HOME
    mkdir -p "${HOME}"
    unset XDG_CONFIG_HOME DBX_CONTAINER_CUSTOM_HOME DBX_CONTAINER_HOME_PREFIX
    CONFIG="${HOME}/.config/worktool/config"
}

# Write the state file with the given key=value lines.
_write_config() {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf '%s\n' "$@" >"${CONFIG}"
}

# --- dry-run via env var -----------------------------------------------------

@test "WORKTOOL_DRY_RUN=1 prints the distrobox command and executes nothing" {
    run --separate-stderr env WORKTOOL_DRY_RUN=1 "${ASSEMBLE}" --file "${VALID}"
    assert_success
    assert_output "distrobox assemble create --file ${VALID}"
    assert [ ! -f "${MARKER}" ]
}

# --- dry-run via flag --------------------------------------------------------

@test "--dry-run flag prints the distrobox command and executes nothing" {
    run --separate-stderr "${ASSEMBLE}" --dry-run --file "${VALID}"
    assert_success
    assert_output "distrobox assemble create --file ${VALID}"
    assert [ ! -f "${MARKER}" ]
}

# --- default manifest --------------------------------------------------------

@test "dry-run with the default manifest emits box/dev.ini" {
    cd "${REPO_ROOT}"
    run --separate-stderr "${ASSEMBLE}" --dry-run
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
    run --separate-stderr "${ASSEMBLE}" --dry-run
    assert_success
    assert_output "distrobox assemble create --file ${REPO_ROOT}/box/dev.ini"
}

# --- faithfully re-runnable dry-run (per-argument shell escaping) -------------

@test "dry-run escapes a path with spaces and metachars into one argument" {
    local _dir="${TMP}/we ird;dir\$(x)"
    mkdir -p "${_dir}"
    local _mani="${_dir}/dev.ini"
    printf '[dev]\nimage=ubuntu:26.04\n' >"${_mani}"

    run --separate-stderr "${ASSEMBLE}" --dry-run --file "${_mani}"
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
    assert_output --partial "--home"
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
    assert [ ! -f "${MARKER}" ]
}

@test "an unknown option is refused even when combined with --dry-run: no command is emitted" {
    run "${ASSEMBLE}" --dry-run --bogus --file "${VALID}"
    assert_failure 2
    assert_output "assemble.sh: unknown option '--bogus' (see --help)"
}

# --- box home (issue #198) ---------------------------------------------------

@test "#198: the default box home is ~/<box>-box, logged as (default); stdout keeps the bare command" {
    run --separate-stderr "${ASSEMBLE}" --dry-run --file "${VALID}"
    assert_success
    assert_output "distrobox assemble create --file ${VALID}"
    assert_equal "${stderr:-}" "[INFO] box home: ${HOME}/dev-box (default)"
}

@test "#198: the default box home follows the manifest's box name" {
    printf '[work]\nimage=ubuntu:26.04\n' >"${TMP}/work.ini"
    run --separate-stderr "${ASSEMBLE}" --dry-run --file "${TMP}/work.ini"
    assert_success
    assert_equal "${stderr:-}" "[INFO] box home: ${HOME}/work-box (default)"
}

@test "#198: --home <path> and --home=<path> are the user's choice, logged as (user)" {
    run --separate-stderr "${ASSEMBLE}" --dry-run --home "/srv/my box" --file "${VALID}"
    assert_success
    assert_output "distrobox assemble create --file ${VALID}"
    assert_equal "${stderr:-}" "[INFO] box home: /srv/my box (user)"
    run --separate-stderr "${ASSEMBLE}" --dry-run --home=/srv/other --file "${VALID}"
    assert_success
    assert_equal "${stderr:-}" "[INFO] box home: /srv/other (user)"
}

@test "#198: trailing slashes of --home are dropped (distrobox drops them too)" {
    run --separate-stderr "${ASSEMBLE}" --dry-run --home /srv/box// --file "${VALID}"
    assert_success
    assert_equal "${stderr:-}" "[INFO] box home: /srv/box (user)"
}

@test "#198: --home with no argument is a usage error (exit 2), nothing runs" {
    run "${ASSEMBLE}" --dry-run --file "${VALID}" --home
    assert_failure 2
    assert_output "assemble.sh: --home requires a path argument (see --help)"
    assert [ ! -f "${MARKER}" ]
}

@test "#198: a relative, empty or root --home is a usage error (exit 2), nothing runs" {
    run "${ASSEMBLE}" --dry-run --home dev-box --file "${VALID}"
    assert_failure 2
    assert_output "assemble.sh: --home needs an absolute path, got 'dev-box' (see --help)"
    run "${ASSEMBLE}" --dry-run --home= --file "${VALID}"
    assert_failure 2
    assert_output "assemble.sh: --home needs an absolute path, got '' (see --help)"
    run "${ASSEMBLE}" --dry-run --home / --file "${VALID}"
    assert_failure 2
    assert_output "assemble.sh: --home cannot be the root directory (see --help)"
    assert [ ! -f "${MARKER}" ]
}

@test "#198: a --home holding a newline is a usage error (exit 2)" {
    run "${ASSEMBLE}" --dry-run --home $'/srv/a\nb' --file "${VALID}"
    assert_failure 2
    assert_output "assemble.sh: --home cannot hold a newline or carriage return (see --help)"
}

@test "#198: --home is parsed with the whole command line: --home x --bogus is still exit 2 on --bogus" {
    run "${ASSEMBLE}" --home /srv/box --bogus --help
    assert_failure 2
    assert_output "assemble.sh: unknown option '--bogus' (see --help)"
}

@test "#198: a stored user home is used when --home is not given; --home still wins" {
    _write_config 'box=dev' 'box.source=default' 'home=/srv/kept' 'home.source=user'
    run --separate-stderr "${ASSEMBLE}" --dry-run --file "${VALID}"
    assert_success
    assert_equal "${stderr:-}" "[INFO] box home: /srv/kept (user)"
    run --separate-stderr "${ASSEMBLE}" --dry-run --home /srv/new --file "${VALID}"
    assert_success
    assert_equal "${stderr:-}" "[INFO] box home: /srv/new (user)"
}

@test "#198: a stored default-sourced home is re-derived, not pinned" {
    _write_config 'home=/srv/old-default' 'home.source=default'
    run --separate-stderr "${ASSEMBLE}" --dry-run --file "${VALID}"
    assert_success
    assert_equal "${stderr:-}" "[INFO] box home: ${HOME}/dev-box (default)"
}

@test "#198: a stored home that is not an absolute path is refused (exit 1), nothing runs" {
    _write_config 'home=dev-box' 'home.source=user'
    run "${ASSEMBLE}" --file "${VALID}"
    assert_failure 1
    assert_output "[ERROR] ${CONFIG}: invalid value 'dev-box' for home (expected an absolute path)"
    assert [ ! -f "${MARKER}" ]
    _write_config 'home=/srv/box' 'home.source=guess'
    run "${ASSEMBLE}" --file "${VALID}"
    assert_failure 1
    assert_output "[ERROR] ${CONFIG}: invalid value 'guess' for home.source (expected default|user)"
}

@test "#198: a manifest that sets distrobox's own home= key is refused (exit 1): --home owns the box HOME" {
    printf '[dev]\nimage=ubuntu:26.04\n  home=/srv/elsewhere\n' >"${TMP}/home.ini"
    run "${ASSEMBLE}" --dry-run --file "${TMP}/home.ini"
    assert_failure 1
    assert_output --partial "[ERROR] manifest sets 'home=', which would override --home"
    refute_output --partial "distrobox assemble create"
}

@test "#198: dry-run records nothing in the state file" {
    run "${ASSEMBLE}" --dry-run --home /srv/box --file "${VALID}"
    assert_success
    assert [ ! -e "${CONFIG}" ]
}

# --- errexit (issue #195) ----------------------------------------------------

@test "assemble.sh runs under set -euo pipefail (one set line, errexit included)" {
    run grep -E '^set -[a-z]+( pipefail)?$' "${ASSEMBLE}"
    assert_success
    assert_output 'set -euo pipefail'
}
