#!/usr/bin/env bats
# test/integration/assemble_spec.bats - assemble -> distrobox wiring (M2)
#
# Proves the real (non-dry-run) path wires script/box/assemble.sh to the
# `distrobox assemble create --file box/dev.ini` invocation end-to-end,
# without needing real distrobox: a MOCK `distrobox` on PATH records the
# arguments it was called with, and the spec asserts on them.
#
# A real `distrobox assemble` against a real engine is the system tier's
# job and lives in M2: test/system/real_engine_spec.bats (docker-in-docker)
# proves the delivered manifest builds a usable box; M5 keeps only the
# broader environment matrix (real hardware, non-root user, other images).
# This integration test verifies the wiring, not a real container build.
#
# Issue #198 (box HOME): the resolved box home reaches distrobox as
# DBX_CONTAINER_CUSTOM_HOME (distrobox-create's documented variable; argv
# is unchanged), is recorded as `home=` / `home.source=` in the state file
# after a successful run, and an EXISTING box whose HOME differs is refused
# (exit 1, nothing changed). The existing box's HOME is read from the
# container manager (`inspect`, the `--home` distrobox handed its init); a
# fake `docker` below answers that probe.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    ASSEMBLE="${REPO_ROOT}/script/box/assemble.sh"
    MOCKBIN="${BATS_TEST_TMPDIR}/bin"
    export RECORD="${BATS_TEST_TMPDIR}/distrobox.args"
    export ENV_RECORD="${BATS_TEST_TMPDIR}/distrobox.home"
    mkdir -p "${MOCKBIN}"
    # Record-only stub: write each arg on its OWN line (per-arg, not $*), so a
    # path containing spaces or shell metachars stays a single recorded token.
    # Issue #198: also record the box home distrobox receives in its
    # environment. Exit FAKE_DBX_RC (default 0).
    cat >"${MOCKBIN}/distrobox" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${RECORD}"
printf '%s\n' "${DBX_CONTAINER_CUSTOM_HOME-<unset>}" >"${ENV_RECORD}"
exit "${FAKE_DBX_RC:-0}"
EOF
    chmod +x "${MOCKBIN}/distrobox"

    # Issue #198: a fake container manager, installed as docker AND podman
    # (which one is asked is part of the contract). `ps -a` lists the
    # container names: `dev` among them only when FAKE_BOX_HOME is set;
    # FAKE_PS_RC makes the listing fail. `inspect` answers like docker: the
    # entrypoint args carry `--home <FAKE_BOX_HOME>`; FAKE_INSPECT_RC makes
    # it fail. Each call is recorded with the name it was called by.
    export INSPECT_RECORD="${BATS_TEST_TMPDIR}/docker.inspect"
    export PS_RECORD="${BATS_TEST_TMPDIR}/manager.ps"
    cat >"${MOCKBIN}/docker" <<'EOF2'
#!/usr/bin/env bash
case "$1" in
    ps)
        printf '%s %s\n' "${0##*/}" "$*" >>"${PS_RECORD}"
        [[ "${FAKE_PS_RC:-0}" -eq 0 ]] || exit "${FAKE_PS_RC}"
        printf '%s\n' devbox other
        [[ -z "${FAKE_BOX_HOME:-}" ]] || printf '%s\n' dev
        ;;
    inspect)
        printf '%s\n' "$@" >"${INSPECT_RECORD}"
        [[ "${FAKE_INSPECT_RC:-0}" -eq 0 ]] || exit "${FAKE_INSPECT_RC}"
        printf '%s\n' -v --name root --home "${FAKE_BOX_HOME}" --init 0
        ;;
    *) exit 2 ;;
esac
EOF2
    chmod +x "${MOCKBIN}/docker"
    cp "${MOCKBIN}/docker" "${MOCKBIN}/podman"
    PATH="${MOCKBIN}:${PATH}"

    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    mkdir -p "${HOME}"
    unset XDG_CONFIG_HOME DBX_CONTAINER_CUSTOM_HOME DBX_CONTAINER_HOME_PREFIX FAKE_BOX_HOME \
        FAKE_PS_RC FAKE_INSPECT_RC
    export DBX_CONTAINER_MANAGER=docker
    CONFIG="${HOME}/.config/worktool/config"
}

@test "mock distrobox is the one that will be resolved on PATH" {
    run command -v distrobox
    assert_success
    assert_output "${MOCKBIN}/distrobox"
}

@test "assemble invokes distrobox assemble create with the dev manifest" {
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_success
    # Args are recorded one-per-line; assert each token independently.
    run cat "${RECORD}"
    assert_line --index 0 "assemble"
    assert_line --index 1 "create"
    assert_line --index 2 "--file"
    assert_line --index 3 "box/dev.ini"
}

@test "assemble validates box/dev.ini before invoking distrobox" {
    assert [ -f "${REPO_ROOT}/box/dev.ini" ]
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_success
    # The stub only runs after validation passes; its record must exist.
    assert [ -f "${RECORD}" ]
}

@test "assemble from outside the repo passes the resolved absolute path" {
    # From outside the repo, the relative default only resolves against
    # REPO_ROOT; distrobox must receive that same resolved absolute path, not
    # a bare `box/dev.ini` that would not exist from here.
    cd "${BATS_TEST_TMPDIR}"
    run "${ASSEMBLE}"
    assert_success
    run cat "${RECORD}"
    assert_line --index 2 "--file"
    assert_line --index 3 "${REPO_ROOT}/box/dev.ini"
}

@test "an invalid manifest never invokes distrobox" {
    # Validation must fail-fast BEFORE any real distrobox call: the mock must
    # never run (no record file) and the wrapper must exit non-zero.
    local _bad="${BATS_TEST_TMPDIR}/bad.ini"
    printf '[dev]\n' >"${_bad}"
    run "${ASSEMBLE}" --file "${_bad}"
    assert_failure
    assert [ ! -f "${RECORD}" ]
}

@test "an image with an unbalanced quote never invokes distrobox" {
    # distrobox-assemble sources `image='ubuntu:26.04"` as a shell
    # assignment, where the unbalanced quote is a syntax error. worktool's
    # pre-flight must reject it (exit 1, its own clear message) so distrobox
    # is never called: the mock records zero calls.
    local _bad="${BATS_TEST_TMPDIR}/unbalanced.ini"
    printf "[dev]\nimage='ubuntu:26.04\"\n" >"${_bad}"
    run "${ASSEMBLE}" --file "${_bad}"
    assert_failure 1
    assert_output --partial "unbalanced quote"
    assert [ ! -f "${RECORD}" ]
}

# --- box home (issue #198) ----------------------------------------------------

@test "#198: the default box home reaches distrobox as DBX_CONTAINER_CUSTOM_HOME; argv is unchanged" {
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_success
    assert_line "[INFO] box home: ${HOME}/dev-box (default)"
    run cat "${ENV_RECORD}"
    assert_output "${HOME}/dev-box"
    run cat "${RECORD}"
    assert_output "$(printf 'assemble\ncreate\n--file\nbox/dev.ini')"
}

@test "#198: --home reaches distrobox verbatim (spaces kept)" {
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}" --home "${BATS_TEST_TMPDIR}/my box"
    assert_success
    run cat "${ENV_RECORD}"
    assert_output "${BATS_TEST_TMPDIR}/my box"
}

@test "#198: an inherited DBX_CONTAINER_CUSTOM_HOME never wins over the resolved home" {
    cd "${REPO_ROOT}"
    DBX_CONTAINER_CUSTOM_HOME=/srv/stray run "${ASSEMBLE}"
    assert_success
    run cat "${ENV_RECORD}"
    assert_output "${HOME}/dev-box"
}

@test "#198: a successful run records home= and home.source= in the state file, keeping the other lines" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf '# note\nauto-enter=no\nauto-enter.source=user\nhome=/srv/old\nhome.source=default\n' >"${CONFIG}"
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}" --home /srv/box
    assert_success
    assert_line "[INFO] recorded box home in ${CONFIG}"
    run cat "${CONFIG}"
    assert_output "$(printf '# note\nauto-enter=no\nauto-enter.source=user\nhome=/srv/box\nhome.source=user')"
}

@test "#198: without a state file the run creates it with the home lines" {
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_success
    run grep -v '^#' "${CONFIG}"
    assert_output "$(printf 'home=%s/dev-box\nhome.source=default' "${HOME}")"
}

@test "#198: a failed distrobox run records nothing" {
    cd "${REPO_ROOT}"
    FAKE_DBX_RC=1 run "${ASSEMBLE}" --home /srv/box
    assert_failure
    assert [ ! -e "${CONFIG}" ]
}

@test "#198: an existing box with a different HOME is refused: exit 1, the recreate commands, nothing changed" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'home=/srv/old\nhome.source=user\n' >"${CONFIG}"
    cd "${REPO_ROOT}"
    FAKE_BOX_HOME=/srv/old run "${ASSEMBLE}" --home /srv/new
    assert_failure 1
    assert_line "[ERROR] box 'dev' already exists with HOME /srv/old; distrobox sets a box's HOME only when the box is created, so it cannot become /srv/new. Nothing was changed."
    assert_line "[ERROR] to use /srv/new, remove the box and recreate it (the files under /srv/old stay on disk):"
    assert_line "[ERROR]   distrobox rm dev"
    assert_line "[ERROR]   just box assemble --home /srv/new"
    assert_line "[ERROR] or keep the current HOME: just box assemble --home /srv/old"
    # distrobox never ran, the state file is untouched.
    assert [ ! -f "${RECORD}" ]
    run cat "${CONFIG}"
    assert_output "$(printf 'home=/srv/old\nhome.source=user')"
    # The probe asked the manager about the box by name.
    run cat "${INSPECT_RECORD}"
    assert_line --index 0 "inspect"
    assert_line "dev"
}

@test "#198: the refusal quotes a path with spaces so the command can be pasted" {
    cd "${REPO_ROOT}"
    FAKE_BOX_HOME=/srv/old run "${ASSEMBLE}" --home "/srv/my box"
    assert_failure 1
    assert_line "[ERROR]   just box assemble --home /srv/my\\ box"
}

@test "#198: an existing box with a different HOME than the DEFAULT is refused too (no --home given)" {
    cd "${REPO_ROOT}"
    FAKE_BOX_HOME=/srv/legacy run "${ASSEMBLE}"
    assert_failure 1
    assert_line --partial "already exists with HOME /srv/legacy"
    assert_line "[ERROR]   just box assemble"
    assert [ ! -f "${RECORD}" ]
    assert [ ! -e "${CONFIG}" ]
}

@test "#198: an existing box with the SAME HOME proceeds (distrobox leaves it alone) and records it" {
    cd "${REPO_ROOT}"
    FAKE_BOX_HOME=/srv/box run "${ASSEMBLE}" --home /srv/box/
    assert_success
    assert [ -f "${RECORD}" ]
    run cat "${CONFIG}"
    assert_line "home=/srv/box"
}

@test "#198: dry-run never probes the container manager" {
    cd "${REPO_ROOT}"
    FAKE_BOX_HOME=/srv/old run "${ASSEMBLE}" --dry-run --home /srv/new
    assert_success
    assert [ ! -f "${INSPECT_RECORD}" ]
    assert [ ! -f "${PS_RECORD}" ]
}

@test "#198 r1: with no container manager to ask, the run is refused (exit 1): nothing runs, nothing recorded" {
    cd "${REPO_ROOT}"
    DBX_CONTAINER_MANAGER=lilipod run "${ASSEMBLE}" --home /srv/new
    assert_failure 1
    assert_output --partial "[ERROR] cannot tell whether box 'dev' already exists: container manager 'lilipod' not found on PATH; nothing was changed"
    assert [ ! -f "${RECORD}" ]
    assert [ ! -e "${CONFIG}" ]
}

@test "#198 r1: a container listing that fails is refused (exit 1), never read as 'no such box'" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'home=/srv/old\nhome.source=user\n' >"${CONFIG}"
    cd "${REPO_ROOT}"
    FAKE_PS_RC=125 run "${ASSEMBLE}" --home /srv/new
    assert_failure 1
    assert_output --partial "[ERROR] cannot tell whether box 'dev' already exists: 'docker ps' failed; nothing was changed"
    assert [ ! -f "${RECORD}" ]
    run cat "${CONFIG}"
    assert_output "$(printf 'home=/srv/old\nhome.source=user')"
}

@test "#198 r1: an existing box whose inspect fails is refused (exit 1): its HOME cannot be read" {
    cd "${REPO_ROOT}"
    FAKE_BOX_HOME=/srv/old FAKE_INSPECT_RC=125 run "${ASSEMBLE}" --home /srv/new
    assert_failure 1
    assert_output --partial "[ERROR] box 'dev' already exists, but its HOME cannot be read from the container manager; nothing was changed"
    assert [ ! -f "${RECORD}" ]
    assert [ ! -e "${CONFIG}" ]
}

@test "#198 r1: a missing box is told from the listing: no 'dev' in it, distrobox runs and the home is recorded" {
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}" --home /srv/new
    assert_success
    assert [ -f "${RECORD}" ]
    assert [ ! -f "${INSPECT_RECORD}" ]
    run cat "${CONFIG}"
    assert_line "home=/srv/new"
}

@test "#198 r1: the manager chosen in distrobox.conf is the one asked (DBX_CONTAINER_MANAGER unset)" {
    mkdir -p "${HOME}/.config/distrobox"
    printf '# chosen by the user\ncontainer_manager="podman"\n' \
        >"${HOME}/.config/distrobox/distrobox.conf"
    cd "${REPO_ROOT}"
    DBX_CONTAINER_MANAGER='' run "${ASSEMBLE}"
    assert_success
    run cat "${PS_RECORD}"
    assert_output --regexp '^podman ps '
}

@test "#198 r1: ~/.distroboxrc overrides distrobox.conf, and DBX_CONTAINER_MANAGER overrides both" {
    mkdir -p "${HOME}/.config/distrobox"
    printf 'container_manager=podman\n' >"${HOME}/.config/distrobox/distrobox.conf"
    printf "container_manager='docker'\n" >"${HOME}/.distroboxrc"
    cd "${REPO_ROOT}"
    DBX_CONTAINER_MANAGER='' run "${ASSEMBLE}"
    assert_success
    run cat "${PS_RECORD}"
    assert_output --regexp '^docker ps '
    rm -f "${PS_RECORD}"
    DBX_CONTAINER_MANAGER=podman run "${ASSEMBLE}"
    assert_success
    run cat "${PS_RECORD}"
    assert_output --regexp '^podman ps '
}

@test "#198 r2: a trailing comment on container_manager= is read the way the shell reads it" {
    mkdir -p "${HOME}/.config/distrobox"
    printf 'container_manager=docker\n' >"${HOME}/.config/distrobox/distrobox.conf"
    printf 'container_manager="podman"  # mine\n' >"${HOME}/.distroboxrc"
    cd "${REPO_ROOT}"
    DBX_CONTAINER_MANAGER='' run "${ASSEMBLE}"
    assert_success
    run cat "${PS_RECORD}"
    assert_output --regexp '^podman ps '
}

@test "#198 r2: a container_manager= line that cannot be read as a name is refused (exit 1), never skipped" {
    local _bad
    mkdir -p "${HOME}/.config/distrobox"
    printf 'container_manager=podman\n' >"${HOME}/.config/distrobox/distrobox.conf"
    cd "${REPO_ROOT}"
    for _bad in 'container_manager=""' "container_manager=\$(echo docker)"; do
        printf '%s\n' "${_bad}" >"${HOME}/.distroboxrc"
        DBX_CONTAINER_MANAGER='' run "${ASSEMBLE}" --home /srv/new
        assert_failure 1
        assert_output --partial "[ERROR] cannot tell whether box 'dev' already exists: cannot read container_manager in ${HOME}/.distroboxrc; nothing was changed"
        assert [ ! -f "${PS_RECORD}" ]
        assert [ ! -f "${RECORD}" ]
        assert [ ! -e "${CONFIG}" ]
    done
}

@test "#198 r1: the refusal keeps --file, so the rebuild hint assembles the same manifest" {
    local _ini="${BATS_TEST_TMPDIR}/my box.ini"
    printf '[dev]\nimage=ubuntu:26.04\n' >"${_ini}"
    cd "${BATS_TEST_TMPDIR}"
    FAKE_BOX_HOME=/srv/old run "${ASSEMBLE}" --file "my box.ini" --home /srv/new
    assert_failure 1
    # The hint names the manifest by its absolute path (the recipe runs
    # from the repo root, not from where the user stood), shell-quoted.
    local _abs
    _abs="$(printf '%q' "$(cd -P -- "${BATS_TEST_TMPDIR}" && pwd)/my box.ini")"
    assert_line "[ERROR]   just box assemble --file ${_abs} --home /srv/new"
    assert_line "[ERROR] or keep the current HOME: just box assemble --file ${_abs} --home /srv/old"
}
