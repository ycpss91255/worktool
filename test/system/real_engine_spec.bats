#!/usr/bin/env bats
# test/system/real_engine_spec.bats - real docker engine (docker-in-docker),
# real-engine group of the system tier (M2)
#
# WHAT THIS PROVES
#   M2's "usable dev box" promise, end to end, against a REAL container
#   engine: the delivered wrapper `script/box/assemble.sh` with the DELIVERED
#   manifest box/dev.ini, through the REAL pinned distrobox (1.8.2.5), makes
#   a REAL dockerd create the `dev` box from ubuntu:26.04, distrobox-init
#   actually runs inside it and installs the manifest's additional_packages
#   (ripgrep fzf tmux fish), and the box is usable: `distrobox enter dev --
#   rg --version` and `distrobox enter dev -- fzf --version` succeed. A
#   second assemble is idempotent (exit 0, still exactly one `dev`), and
#   `distrobox rm -f dev` removes the box.
#
#   M3 (issue #160) adds tmux and fish to the manifest: `just box setup`
#   points the terminal at `distrobox enter dev -- tmux new -A -s main` and
#   #5 requires "open a terminal, get the box's fish", so both must exist
#   inside the box BEFORE the auto-enter flow can work (their configuration
#   - dotfiles, theme, plugins - stays M5). Two cases assert `distrobox
#   enter dev -- tmux -V` and `distrobox enter dev -- fish --version`
#   succeed and print a version, and echo those versions into the TAP
#   stream as evidence.
#
#   M3 (issues #150, #23) adds the enter-latency GATE: once the box is
#   initialised, the delivered `script/box/bench.sh` measures the real
#   enter latency (`--box dev --runs 5 --warmup 2`) with `--max-ms
#   ENTER_MAX_MS` (the < 300 ms target of doc/design.md, one constant
#   below); the case passes only when bench.sh exits 0, i.e. the SHELL
#   median (the user-perceived time to a prompt: enter + shell start-up)
#   is within the threshold. The shell metric is measured on the box's
#   fish (`--shell 'fish -c exit'`, issue #160): the 300 ms target of
#   issue #22 is judged on the shell the user actually gets, not on `sh`.
#   Both metric lines are still echoed into the TAP stream as evidence. A
#   negative case runs the same bench with `--max-ms 1` and requires exit
#   1 plus bench.sh's threshold message, so the gate is proven to bite on a
#   real box - a green positive case can never be a no-op threshold. The
#   runtime decision (docker + default runc stays; CI measured ~88 ms) is
#   recorded in issue #22.
#
# HOW (docker-in-docker; see doc/manifest.md 測試對應 and issue #129)
#   This spec runs ONLY inside the dedicated runner image
#   (dockerfile/Dockerfile.system-real, based on the official docker:dind
#   image) started with `docker run --rm --privileged` by
#   `script/test/test.sh --system-real`. The runner's entry script
#   (script/test/system-real-entry.sh) starts an isolated dockerd inside the
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
#   Real-host latency (the gate judges the DinD box on the CI runner; the
#   numbers of a real machine are collected in the human checklist, issue
#   #22), the terminal auto-enter flow, and the broader environment matrix
#   (real hardware, non-root user, other images) - those belong to M3/M5
#   and the human checklist.
#
# TIMEOUTS
#   Pulling ubuntu:26.04 and apt-installing distrobox's own dependencies plus
#   ripgrep/fzf/tmux/fish inside the box take minutes. Every long step is wrapped in
#   `timeout` with a generous but bounded budget, and every short engine
#   query (info / ps / inspect / logs, diagnostics included) goes through
#   `_docker`, which bounds it too - a wedged daemon cannot hold a case or
#   its failure diagnostics open. On failure the daemon log and the box's
#   own log are printed so a red run is diagnosable.

load "${BATS_TEST_DIRNAME}/../helper/common"

# Bounded budgets (seconds) for the long steps.
ASSEMBLE_TIMEOUT=600      # image pull + docker create (no start yet)
FIRST_ENTER_TIMEOUT=900   # first start: distrobox-init + apt installs
ENTER_TIMEOUT=300         # subsequent enters (box already initialised)
RM_TIMEOUT=120
QUERY_TIMEOUT=60          # short engine queries: info / ps / inspect / logs

# Enter-latency gate (M3, issue #23): the SHELL median bench.sh measures on
# the real box must not exceed this many milliseconds - the "< ~300 ms
# time to a prompt" performance target of doc/design.md. The number lives
# HERE only; doc/design.md and doc/manifest.md refer to this constant.
ENTER_MAX_MS=300

setup() {
    ASSEMBLE="${REPO_ROOT}/script/box/assemble.sh"
    BENCH="${REPO_ROOT}/script/box/bench.sh"

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

# --- bounded engine queries + diagnostics ------------------------------------

# Every short engine query goes through here: a hard bound (SIGTERM at
# QUERY_TIMEOUT, SIGKILL 5s later) so a wedged daemon cannot hang a case or
# the diagnostics that run when one fails.
_docker() {
    timeout -k 5 "${QUERY_TIMEOUT}" docker "$@"
}

# Names of every container the nested daemon knows about, one per line.
_container_names() {
    _docker ps -a --format '{{.Names}}'
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
    _docker ps -a 2>&1 || true
    if [[ -n "${WORKTOOL_DOCKERD_LOG:-}" && -f "${WORKTOOL_DOCKERD_LOG}" ]]; then
        echo "--- dockerd log (tail): ${WORKTOOL_DOCKERD_LOG}"
        tail -n 60 "${WORKTOOL_DOCKERD_LOG}" 2>&1 || true
    fi
    if [[ "$(_count_named dev)" -gt 0 ]]; then
        echo "--- docker logs dev (tail)"
        _docker logs --tail 80 dev 2>&1 || true
    fi
}

# --- preflight: a live engine and the pinned distrobox -----------------------

@test "preflight: a real docker engine is live inside the runner" {
    run _docker info --format '{{.ServerVersion}} driver={{.Driver}} cgroup={{.CgroupDriver}}/{{.CgroupVersion}}'
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
    run _docker inspect dev --format '{{.Config.Image}} {{index .Config.Labels "manager"}}'
    assert_success
    assert_output "ubuntu:26.04 distrobox"
}

# Evidence: echo the lines $2.. (a case passes its `${lines[@]}`) into the
# TAP stream (fd 3 is bats' original stdout; `# ` keeps the stream
# TAP-clean) and into the case's own output, prefixed with $1.
_log_lines() {
    local _tag="$1" _l
    shift
    for _l in "$@"; do
        printf '# %s: %s\n' "${_tag}" "${_l}" >&3
        echo "${_tag}: ${_l}"
    done
}

# --- (c) the box is usable: the manifest tools run inside it -----------------

@test "real engine: distrobox enter dev -- rg --version prints a ripgrep version (first start runs distrobox-init + apt)" {
    cd "${REPO_ROOT}"
    run timeout "${FIRST_ENTER_TIMEOUT}" distrobox enter dev -- rg --version </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^ripgrep [0-9]+\.[0-9]+'
    # The box is now a running, initialised container.
    run _docker inspect dev --format '{{.State.Status}}'
    assert_output "running"
}

@test "real engine: distrobox enter dev -- fzf --version prints a version" {
    cd "${REPO_ROOT}"
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- fzf --version </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^[0-9]+\.[0-9]+'
}

# M3 (issue #160): tmux and fish are the auto-enter prerequisite - the
# terminal profile written by `just box setup` runs `distrobox enter dev --
# tmux new -A -s main`, and #5 wants the box's fish behind it. Their
# versions go into the TAP stream as evidence.
@test "real engine: distrobox enter dev -- tmux -V prints a tmux version (auto-enter prerequisite)" {
    cd "${REPO_ROOT}"
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- tmux -V </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^tmux [0-9]+\.[0-9]+'
    _log_lines tmux "${lines[@]}"
}

@test "real engine: distrobox enter dev -- fish --version prints a fish version (auto-enter prerequisite)" {
    cd "${REPO_ROOT}"
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- fish --version </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^fish, version [0-9]+\.[0-9]+'
    _log_lines fish "${lines[@]}"
}

# --- (d) enter latency: bench.sh gates the real box (--max-ms) ----------------

# Regex of one bench.sh millisecond value (`88.7`, `120.0`).
BENCH_NUM='[0-9]+(\.[0-9]+)?'

# Assert that the last `run` printed both bench.sh metric lines (stdout);
# they must appear whether the threshold passed or not.
_assert_metric_lines() {
    assert_line --regexp "^enter: min=${BENCH_NUM} median=${BENCH_NUM} max=${BENCH_NUM} ms$"
    assert_line --regexp "^shell: min=${BENCH_NUM} median=${BENCH_NUM} max=${BENCH_NUM} ms$"
}

# The shell metric is measured on the box's fish (issue #160): `fish -c
# exit` is the cheapest fish start-up, i.e. the floor of "time to a fish
# prompt". This constant is what the gate below hands to bench.sh --shell.
BENCH_SHELL='fish -c exit'

@test "real engine: bench.sh --box dev --runs 5 --warmup 2 --shell 'fish -c exit' --max-ms ENTER_MAX_MS exits 0 (enter-latency gate on fish) and prints the enter and shell metric lines" {
    cd "${REPO_ROOT}"
    # 2 metrics x (2 warmup + 5 runs) = 14 enters of an initialised box.
    # Exit 0 IS the gate: bench.sh returns 1 when the shell median exceeds
    # --max-ms, so a slow box (or a slow fish start-up) fails this case.
    run timeout "${ENTER_TIMEOUT}" bash "${BENCH}" \
        --box dev --runs 5 --warmup 2 --shell "${BENCH_SHELL}" \
        --max-ms "${ENTER_MAX_MS}" </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    _assert_metric_lines
    # The shell metric really ran fish (bench.sh names the timed command).
    assert_line --regexp "^\[INFO\] shell: 2 warmup \+ 5 run\(s\) of 'distrobox enter dev -- ${BENCH_SHELL}' done$"
    # The threshold was really evaluated (not merely accepted as an option).
    assert_line --regexp "^\[INFO\] shell median ${BENCH_NUM} ms within --max-ms ${ENTER_MAX_MS}$"
    _log_lines bench "${lines[@]}"
}

@test "real engine: bench.sh --box dev --runs 1 --warmup 0 --shell 'fish -c exit' --max-ms 1 exits 1 with the threshold message (the gate bites on a real box)" {
    cd "${REPO_ROOT}"
    # 2 metrics x (0 warmup + 1 run) = 2 enters. A real engine round trip
    # is never below 1 ms, so the gate must refuse: exit 1, both metric
    # lines still printed, the reason on stderr in bench.sh's own words.
    run timeout "${ENTER_TIMEOUT}" bash "${BENCH}" \
        --box dev --runs 1 --warmup 0 --shell "${BENCH_SHELL}" --max-ms 1 </dev/null
    [[ "${status}" -eq 1 ]] || _diag
    assert_failure 1
    _assert_metric_lines
    assert_line --regexp "^\[ERROR\] shell median ${BENCH_NUM} ms exceeds --max-ms 1$"
    refute_line --regexp '^\[INFO\] shell median .* within --max-ms'
    _log_lines bench-gate "${lines[@]}"
}

# --- (e) idempotency: assembling again neither errors nor duplicates ---------

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

# --- (f) teardown: distrobox rm removes the box ------------------------------

@test "real engine: distrobox rm -f dev removes the box from the engine" {
    run timeout "${RM_TIMEOUT}" distrobox rm -f dev </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    run _count_named dev
    assert_output "0"
}
