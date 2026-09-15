#!/usr/bin/env bats
# test/system/real_engine_spec.bats - real docker engine (docker-in-docker),
# real-engine group of the system tier (M2)
#
# WHAT THIS PROVES
#   M2's "usable dev box" promise, end to end, against a REAL container
#   engine: the delivered wrapper `script/assemble.sh` with the DELIVERED
#   manifest box/dev.ini, through the REAL pinned distrobox (1.8.2.5), makes
#   a REAL dockerd create the `dev` box from ubuntu:26.04, distrobox-init
#   actually runs inside it and installs the manifest's additional_packages
#   (ripgrep fzf), and the box is usable: `distrobox enter dev -- rg
#   --version` and `distrobox enter dev -- fzf --version` succeed. A second
#   assemble is idempotent (exit 0, still exactly one `dev`), and
#   `distrobox rm -f dev` removes the box.
#
# HOW (docker-in-docker; see doc/manifest.md 測試對應 and issue #129)
#   This spec runs ONLY inside the dedicated runner image
#   (dockerfile/Dockerfile.system-real, based on the official docker:dind
#   image) started with `docker run --rm --privileged` by
#   `script/ci/ci.sh --system-real-only`. The runner's entry script
#   (script/ci/system-real-entry.sh) starts an isolated dockerd inside the
#   runner container, waits for it, then runs this spec through the normal
#   bats tier gate (--ci-system-real). Every container, image and volume the
#   test creates lives in that nested daemon and dies with the runner
#   container: the host daemon never sees the box. The host installs
#   nothing.
#
#   distrobox runs as root here (uid 0 inside the runner), which upstream
#   treats as "rootful, logged in as root": no sudo is prepended, the box
#   user is root with the fresh HOME below. That is fine for this proof and
#   is documented in doc/manifest.md.
#
# WHAT THIS DOES NOT PROVE
#   Performance targets (enter latency), the terminal auto-enter flow, and
#   the broader environment matrix (real hardware, non-root user, other
#   images) - those belong to M3/M5 and the human checklist.
#
# TIMEOUTS
#   Pulling ubuntu:26.04 and apt-installing distrobox's own dependencies plus
#   ripgrep/fzf inside the box take minutes. Every long step is wrapped in
#   `timeout` with a generous but bounded budget; on failure the daemon log
#   and the box's own log are printed so a red run is diagnosable.

load "${BATS_TEST_DIRNAME}/../helper/common"

# Bounded budgets (seconds) for the long steps.
ASSEMBLE_TIMEOUT=600      # image pull + docker create (no start yet)
FIRST_ENTER_TIMEOUT=900   # first start: distrobox-init + apt installs
ENTER_TIMEOUT=300         # subsequent enters (box already initialised)
RM_TIMEOUT=120

setup() {
    ASSEMBLE="${REPO_ROOT}/script/assemble.sh"

    # Hermetic distrobox environment: a fresh HOME (no ~/.distroboxrc, no
    # cache), docker selected explicitly, no desktop entry generation.
    #
    # The box persists across the cases in this file (create -> enter ->
    # idempotency -> rm) and its HOME is bind-mounted into it at create
    # time, so the HOME must be per-FILE (stable across cases), not the
    # per-test BATS_TEST_TMPDIR that bats removes after each case.
    export HOME="${BATS_FILE_TMPDIR}/home"
    mkdir -p "${HOME}"
    export DBX_CONTAINER_MANAGER=docker
    export DBX_CONTAINER_GENERATE_ENTRY=0
}

# --- diagnostics ------------------------------------------------------------

# Names of every container the nested daemon knows about, one per line.
_container_names() {
    docker ps -a --format '{{.Names}}'
}

# Count of containers named exactly $1.
_count_named() {
    _container_names | grep -c -x -- "$1" || true
}

# Print everything useful when a long step fails: the nested dockerd log
# (path exported by the runner entry) and the box's own log (distrobox-init
# output). bats shows a failed case's output, so plain echo is enough.
_diag() {
    echo "--- docker ps -a"
    docker ps -a 2>&1 || true
    if [[ -n "${WORKTOOL_DOCKERD_LOG:-}" && -f "${WORKTOOL_DOCKERD_LOG}" ]]; then
        echo "--- dockerd log (tail): ${WORKTOOL_DOCKERD_LOG}"
        tail -n 60 "${WORKTOOL_DOCKERD_LOG}" 2>&1 || true
    fi
    if [[ "$(_count_named dev)" -gt 0 ]]; then
        echo "--- docker logs dev (tail)"
        docker logs --tail 80 dev 2>&1 || true
    fi
}

# --- preflight: a live engine and the pinned distrobox -----------------------

@test "preflight: a real docker engine is live inside the runner" {
    run docker info --format '{{.ServerVersion}} driver={{.Driver}} cgroup={{.CgroupDriver}}/{{.CgroupVersion}}'
    assert_success
    assert_output --regexp '^[0-9]+\.[0-9]+\.[0-9]+ driver=.+ cgroup=.+'
    echo "engine: ${output}"
}

@test "preflight: the real pinned distrobox is what runs" {
    [[ -n "${DISTROBOX_VERSION:-}" ]] \
        || fail "DISTROBOX_VERSION not set - this spec runs inside the system-real runner only"
    run distrobox --version
    assert_success
    assert_output "distrobox: ${DISTROBOX_VERSION}"
}

@test "preflight: no dev box exists before the run (fresh nested daemon)" {
    run _count_named dev
    assert_success
    assert_output "0"
}

# --- (b) real assemble: the box is created by the real engine ----------------

@test "real engine: assemble.sh with the delivered box/dev.ini creates the dev box from ubuntu:26.04" {
    cd "${REPO_ROOT}"
    run timeout "${ASSEMBLE_TIMEOUT}" "${ASSEMBLE}" </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_output --partial "Distrobox 'dev' successfully created."

    # Exactly one container named dev now exists in the nested daemon ...
    run _count_named dev
    assert_output "1"
    # ... created from the manifest's image, managed by distrobox.
    run docker inspect dev --format '{{.Config.Image}} {{index .Config.Labels "manager"}}'
    assert_success
    assert_output "ubuntu:26.04 distrobox"
}

# --- (c) the box is usable: the manifest tools run inside it -----------------

@test "real engine: distrobox enter dev -- rg --version prints a ripgrep version (first start runs distrobox-init + apt)" {
    cd "${REPO_ROOT}"
    run timeout "${FIRST_ENTER_TIMEOUT}" distrobox enter dev -- rg --version </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^ripgrep [0-9]+\.[0-9]+'
    # The box is now a running, initialised container.
    run docker inspect dev --format '{{.State.Status}}'
    assert_output "running"
}

@test "real engine: distrobox enter dev -- fzf --version prints a version" {
    cd "${REPO_ROOT}"
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- fzf --version </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^[0-9]+\.[0-9]+'
}

# --- (d) idempotency: assembling again neither errors nor duplicates ---------

@test "real engine: a second assemble.sh run exits 0 and does not duplicate the dev box" {
    cd "${REPO_ROOT}"
    run timeout "${ASSEMBLE_TIMEOUT}" "${ASSEMBLE}" </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    # Upstream's own idempotency message (distrobox-assemble): the existing
    # box is left alone, nothing is re-created.
    assert_output --partial "dev already exists"
    refute_output --partial "successfully created"
    run _count_named dev
    assert_output "1"
    # And it is still the same usable box.
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- rg --version </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^ripgrep [0-9]+\.[0-9]+'
}

# --- (e) teardown: distrobox rm removes the box ------------------------------

@test "real engine: distrobox rm -f dev removes the box from the engine" {
    run timeout "${RM_TIMEOUT}" distrobox rm -f dev </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    run _count_named dev
    assert_output "0"
}
