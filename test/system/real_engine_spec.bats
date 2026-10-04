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
#   M3 (issue #160) adds tmux and fish to the manifest: #5 requires "open a
#   terminal, get the box's fish", and tmux is the tool the user starts in
#   the box (their configuration - dotfiles, theme, plugins - stays M5).
#   Two cases assert `distrobox enter dev -- tmux -V` and `distrobox enter
#   dev -- fish --version` succeed and print a version, and echo those
#   versions into the TAP stream as evidence.
#
#   M3 (issues #179, #360): the terminal runs the enter.sh wrapper and nothing
#   after it - no tmux. distrobox shares /tmp with the host, so the old
#   `-- tmux new -A -s main` attached to a HOST tmux server whenever one
#   was running, and the user got a host shell that looked like the box.
#   Section (e3) starts a tmux server on the runner (the host side) first
#   and proves (1) the delivered command still lands in the box and (2) a
#   `tmux` started in the box gets the box's own server (TMUX_TMPDIR, set
#   by box/dev.ini), whose process lives in the box's mount namespace and
#   which does not list the host session.
#
#   M3 (issue #180): the FIRST enter runs through the delivered entry
#   setup-written command through script/box/enter.sh (issue #434),
#   and asserts that a real first initialisation is observable - the
#   first-launch notice, the host log path and progress lines on stderr -
#   and that the host log file exists and is not empty.
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
#   All three metric lines (enter, shell, and since issue #162 inbox: the
#   shell start-up clocked INSIDE the box by a bash timer, which proves the
#   in-box timer really prints a number on a real box) are still echoed
#   into the TAP stream as evidence. A negative case runs the same bench
#   with `--max-ms 1` and requires exit 1 plus bench.sh's threshold
#   message, so the gate is proven to bite on a real box - a green positive
#   case can never be a no-op threshold. The runtime decision (docker +
#   default runc stays; CI measured ~88 ms) is recorded in issue #22.
#
#   Issue #181 puts a quiet-host precondition in front of the gate: bench.sh
#   first waits for CPU pressure (PSI) `some avg10 <= 2.00` held for 5 s
#   (120 s at most on CI, where test.sh passes CI into the runner) and a
#   host that stays busy, or turns busy mid-run, is exit 3 (inconclusive).
#   Both cases here require their own verdict (0 / 1), so a 3 is red too:
#   CI never skips the gate because the runner is busy. Both cases also
#   require the precondition's evidence line (the PSI path, its value and
#   loadavg, or the warning that no PSI is readable) in the TAP stream.
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

# `run -127` (a control case asserting `command not found`) is a flagged
# run, which bats only accepts once the minimum version is declared.
bats_require_minimum_version 1.5.0

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
    ENTER="${REPO_ROOT}/script/box/enter.sh"

    # Hermetic distrobox environment: a fresh HOME (no ~/.distroboxrc, no
    # cache), docker selected explicitly, no desktop entry generation.
    #
    # The box persists across the cases in this file (create -> enter ->
    # idempotency -> rm) and its HOME is bind-mounted into it at create
    # time, so the HOME must be per-FILE (stable across cases), not the
    # per-test BATS_TEST_TMPDIR that bats removes after each case.
    export HOME="${BATS_FILE_TMPDIR}/home"
    mkdir -p "${HOME}"
    # Issue #198: the box's own HOME, requested with --home. Per-FILE for
    # the same reason as HOME, and deliberately NOT the default
    # ~/dev-box, so the case proves the requested path is the one used.
    BOX_HOME="${BATS_FILE_TMPDIR}/box-home"
    export DBX_CONTAINER_MANAGER=docker
    export DBX_CONTAINER_GENERATE_ENTRY=0

    # The ghostty cases (section (e), issue #172) write their config under
    # this HOME and read it back through a real ghostty, so the managed
    # block travels the same XDG path a user's would. The delivered
    # lib/enter.sh supplies the block markers and the composer, so the
    # test writes the SAME shape `just box setup` writes.
    export XDG_CONFIG_HOME="${HOME}/.config"
    # shellcheck source-path=SCRIPTDIR/../../lib
    # shellcheck source=enter.sh
    source "${REPO_ROOT}/lib/enter.sh"
    # GTK in a container with no GPU and no session bus: software X11 only.
    export LIBGL_ALWAYS_SOFTWARE=1
    export GDK_BACKEND=x11
    export XDG_RUNTIME_DIR="${BATS_FILE_TMPDIR}/run"
    mkdir -p "${XDG_RUNTIME_DIR}"
    chmod 700 "${XDG_RUNTIME_DIR}"
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
    # Issue #199: host user config for assemble to link into the box HOME
    # (read back inside the box by the #199 case below).
    mkdir -p "${HOME}/.ssh"
    printf 'worktool-link-probe\n' >"${HOME}/.ssh/worktool-link-probe"
    printf '[user]\n\tname = worktool-link-probe\n' >"${HOME}/.gitconfig"
    cd "${REPO_ROOT}"
    run timeout "${ASSEMBLE_TIMEOUT}" "${ASSEMBLE}" --home "${BOX_HOME}" </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_output --partial "Distrobox 'dev' successfully created."
    assert_line "[INFO] box home: ${BOX_HOME} (user)"
    assert_line "[INFO] link: ${BOX_HOME}/.ssh -> ${HOME}/.ssh"
    assert_line "[INFO] link: ${BOX_HOME}/.gitconfig -> ${HOME}/.gitconfig"

    # Exactly one container named dev now exists in the nested daemon ...
    run _count_named dev
    assert_output "1"
    # ... created from the manifest's image, managed by distrobox.
    run _docker inspect dev --format '{{.Config.Image}} {{index .Config.Labels "manager"}}'
    assert_success
    assert_output "ubuntu:26.04 distrobox"
}

# Shared evidence interface, also exercised by the acceptance gate fixtures.
# shellcheck source=test/helper/diagnostics.bash
source "${BATS_TEST_DIRNAME}/../helper/diagnostics.bash"

# --- (c) the box is usable: the manifest tools run inside it -----------------

# Issue #434: execute the command setup really writes before any first enter.
# A PTY supplies fish input while preserving the terminal entry command.
@test "ghostty chain cold start (#434): setup-written command reports continuous first-init progress and enters fish" {
    cd "${REPO_ROOT}"
    run "${REPO_ROOT}/script/box/setup.sh" --terminal ghostty --box dev
    assert_success
    local _body _command _log="${HOME}/.cache/worktool/dev-init.log"
    _body="$(enter_block_body "$(enter_ghostty_target)")"
    [[ "${_body}" == 'command = '* ]] || fail "setup wrote no managed command"
    _command="${_body#command = }"
    run _docker inspect --type container -f '{{.State.StartedAt}}' dev
    assert_success
    assert_output --regexp '^0001-01-01'
    WORKTOOL_INIT_INTERVAL=1 WORKTOOL_INIT_TIMEOUT="${FIRST_ENTER_TIMEOUT}" run bash -c '
        printf "%s\n" "$3" | timeout -k 5 "$1" script -qec "$2" /dev/null
    ' _ "${FIRST_ENTER_TIMEOUT}" "${_command}" \
        "fish -c 'printf \"cold-fish=%s\\n\" \"\$FISH_VERSION\"; readlink /proc/self/ns/mnt'; exit"
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    local _out _progress
    _out="$(tr '\r' '\n' <<<"${output}")"
    _progress="$(grep -E 'first launch: .+ - [0-9m]+s elapsed - ' <<<"${_out}" | sort -u | wc -l)" || _progress=0
    [[ "${_progress}" -ge 2 ]] || fail "expected changing progress, got ${_progress}: ${_out}"
    assert_output --partial "first launch of box 'dev'"
    assert_output --partial "full init log: ${_log}"
    assert_output --partial "initialisation complete after"
    [[ "${_out}" =~ cold-fish=[0-9]+\.[0-9]+ ]] || fail "the command did not enter fish: ${_out}"
    [[ "${_out}" == *"$(_dev_mntns)"* ]] || fail "fish did not run in the dev mount namespace"
    assert [ -s "${_log}" ]
    run grep -c 'container_setup_done' "${_log}"
    assert_success
    diagnostic_lines chain-cold "changing progress updates=${_progress}; setup command entered fish in dev"
}

@test "real engine: enter.sh --box dev -- rg --version prints a ripgrep version after cold init" {
    run timeout -k 5 "${ENTER_TIMEOUT}" "${ENTER}" --box dev -- rg --version </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^ripgrep [0-9]+\.[0-9]+'
}

@test "real engine: distrobox enter dev -- fzf --version prints a version" {
    cd "${REPO_ROOT}"
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- fzf --version </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^[0-9]+\.[0-9]+'
}

# M3 (issue #160): fish is the shell #5 wants behind the terminal, and tmux
# is what the user starts inside the box (issue #179: the terminal itself
# starts no tmux). Their versions go into the TAP stream as evidence.
@test "real engine: distrobox enter dev -- tmux -V prints a tmux version (auto-enter prerequisite)" {
    cd "${REPO_ROOT}"
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- tmux -V </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^tmux [0-9]+\.[0-9]+'
    diagnostic_lines tmux "${lines[@]}"
}

@test "real engine: distrobox enter dev -- fish --version prints a fish version (auto-enter prerequisite)" {
    cd "${REPO_ROOT}"
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- fish --version </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^fish, version [0-9]+\.[0-9]+'
    diagnostic_lines fish "${lines[@]}"
}

# --- (c2) the box's own HOME (issue #198) -------------------------------------

@test "real engine (#198): \$HOME inside the box is the path assemble --home asked for" {
    # printenv prints the two values in the order asked, one per line.
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- \
        printenv HOME DISTROBOX_HOST_HOME </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_equal "${lines[0]}" "${BOX_HOME}"
    assert_equal "${lines[1]}" "${HOME}"
    diagnostic_lines box-home "${lines[@]}"
    # distrobox created the directory on the host side, and recorded it.
    assert [ -d "${BOX_HOME}" ]
    run grep -x "home=${BOX_HOME}" "${XDG_CONFIG_HOME}/worktool/config"
    assert_success
}

# Issue #199 (ADR 0002 decision 3): the dev box has its own HOME (BOX_HOME,
# #198), so assemble.sh linked the host user config into it - the first
# assemble case writes that config before it runs. The tools inside the
# box find it where they look: at `$HOME/.ssh` and `$HOME/.gitconfig` of
# the box, not by a host path.
@test "real engine (#199): the user config linked into the box HOME is found at \$HOME inside the box" {
    # The links sit in the box HOME on the host side ...
    assert_equal "$(readlink "${BOX_HOME}/.ssh")" "${HOME}/.ssh"
    assert_equal "$(readlink "${BOX_HOME}/.gitconfig")" "${HOME}/.gitconfig"
    # ... and resolve INSIDE the box, where $HOME is the box's own HOME
    # (quoted heredoc: nothing expands on the host side).
    local _probe="${HOME}/link-probe.sh"
    cat >"${_probe}" <<'PROBE'
printf 'home=%s\n' "$HOME"
printf 'ssh=%s\n' "$(cat "$HOME/.ssh/worktool-link-probe")"
printf 'git=%s\n' "$(sed -n 's/^[[:space:]]*name = //p' "$HOME/.gitconfig")"
PROBE
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- sh "${_probe}" </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line "home=${BOX_HOME}"
    assert_line "ssh=worktool-link-probe"
    assert_line "git=worktool-link-probe"
    diagnostic_lines link "${lines[@]}"
}

# --- (d) enter latency: bench.sh gates the real box (--max-ms) ----------------

# Regex of one bench.sh millisecond value (`88.7`, `120.0`).
BENCH_NUM='[0-9]+(\.[0-9]+)?'

# Assert that the last `run` printed all three bench.sh metric lines
# (stdout); they must appear whether the threshold passed or not. The inbox
# line is the one that can only be produced by a timer that really ran
# inside the box and printed an integer (bench.sh aborts otherwise).
_assert_metric_lines() {
    assert_line --regexp "^enter: min=${BENCH_NUM} median=${BENCH_NUM} max=${BENCH_NUM} ms$"
    assert_line --regexp "^shell: min=${BENCH_NUM} median=${BENCH_NUM} max=${BENCH_NUM} ms$"
    assert_line --regexp "^inbox: min=${BENCH_NUM} median=${BENCH_NUM} max=${BENCH_NUM} ms$"
}

# Assert that the last `run` printed the quiet-host evidence (issue #181):
# the PSI file read, its value and loadavg - or the warning that no PSI
# file is readable and the run went unguarded.
_assert_quiet_host_evidence() {
    assert_line --regexp '^\[INFO\] host quiet: /.+ some avg10=[0-9.]+ <= 2\.00 for 5s; loadavg=.+$|^\[WARN\] no CPU pressure \(PSI\) readable .* measuring anyway; loadavg=.+$'
}

# The shell metric is measured on the box's fish (issue #160): `fish -c
# exit` is the cheapest fish start-up, i.e. the floor of "time to a fish
# prompt". This constant is what the gate below hands to bench.sh --shell.
BENCH_SHELL='fish -c exit'

# Assert that the last `run` timed fish for BOTH shell-shaped metrics, with
# the given warmup / runs counts: the host-side `shell` metric AND the
# in-box `inbox` timer (`bash -c <timer> bench-inbox fish -c exit`). Codex
# round 1 on PR #169: evidence that only names `sh -c :` cannot prove the
# in-box timer ever started fish, so the spec pins the command in both
# INFO lines (bench.sh names the timed command per metric).
_assert_fish_timed() {
    local _warmup="$1" _runs="$2"
    assert_line --regexp "^\[INFO\] shell: ${_warmup} warmup \+ ${_runs} run\(s\) of '.*[/]script/box/enter[.]sh' --distrobox '[^']+' --box 'dev' -- ${BENCH_SHELL}' done$"
    assert_line --regexp "^\[INFO\] inbox: ${_warmup} warmup \+ ${_runs} run\(s\) of '.*[/]script/box/enter[.]sh' --distrobox '[^']+' --box 'dev' -- bash -c <timer> bench-inbox ${BENCH_SHELL}' done$"
    refute_line --regexp "^\[INFO\] (shell|inbox): .* sh -c :' done$"
}

@test "real engine: bench.sh --box dev --runs 5 --warmup 2 --shell 'fish -c exit' --max-ms ENTER_MAX_MS exits 0 (enter-latency gate on fish) and prints the enter, shell and inbox metric lines" {
    cd "${REPO_ROOT}"
    # 3 metrics x (2 warmup + 5 runs) = 21 enters of an initialised box.
    # Exit 0 IS the gate: bench.sh returns 1 when the shell median exceeds
    # --max-ms, so a slow box (or a slow fish start-up) fails this case.
    run timeout "${ENTER_TIMEOUT}" bash "${BENCH}" \
        --box dev --runs 5 --warmup 2 --shell "${BENCH_SHELL}" \
        --max-ms "${ENTER_MAX_MS}" </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    _assert_metric_lines
    # Both the shell metric and the in-box timer really ran fish.
    _assert_fish_timed 2 5
    _assert_quiet_host_evidence
    # The threshold was really evaluated (not merely accepted as an option).
    assert_line --regexp "^\[INFO\] shell median ${BENCH_NUM} ms within --max-ms ${ENTER_MAX_MS}$"
    diagnostic_lines bench "${lines[@]}"
}

@test "real engine: bench.sh --box dev --runs 1 --warmup 0 --shell 'fish -c exit' --max-ms 1 exits 1 with the threshold message (the gate bites on a real box)" {
    cd "${REPO_ROOT}"
    # 3 metrics x (0 warmup + 1 run) = 3 enters. A real engine round trip
    # is never below 1 ms, so the gate must refuse: exit 1, all three metric
    # lines still printed, the reason on stderr in bench.sh's own words.
    run timeout "${ENTER_TIMEOUT}" bash "${BENCH}" \
        --box dev --runs 1 --warmup 0 --shell "${BENCH_SHELL}" --max-ms 1 </dev/null
    [[ "${status}" -eq 1 ]] || _diag
    assert_failure 1
    _assert_metric_lines
    _assert_fish_timed 0 1
    _assert_quiet_host_evidence
    assert_line --regexp "^\[ERROR\] shell median ${BENCH_NUM} ms exceeds --max-ms 1$"
    refute_line --regexp '^\[INFO\] shell median .* within --max-ms'
    diagnostic_lines bench-gate "${lines[@]}"
}

# --- (e) the ghostty chain: a real window enters the real box ----------------
#
# Layer 2 of issue #172: a REAL ghostty, on a REAL (headless) X server,
# reading a REAL managed block, opens a window whose command enters the
# REAL box of the cases above and leaves a marker INSIDE it. Layer 1 (the
# display-free half: the block a real ghostty parses and resolves) is
# test/integration/ghostty_config_spec.bats.
#
# WHY THE WITNESS IS THE MARKER FILE, NOT GHOSTTY'S EXIT CODE
#   With `gtk-single-instance` on, a second `ghostty` only asks an existing
#   primary instance over D-Bus to open the window, and returns 0 without
#   waiting for the command it asked for - so exit 0 proves nothing about
#   that command. The test config therefore
#   pins `gtk-single-instance = false` (asserted below), and what a case
#   accepts as success is the marker the command wrote inside the box. The
#   last case in this section demonstrates the false positive on purpose.
#
# WHY IT CANNOT HANG
#   The config does NOT override `wait-after-command` (default false) or
#   `quit-after-last-window-closed` (default true on Linux), so ghostty
#   closes the window and exits by itself once the command returns; every
#   launch is additionally wrapped in `timeout -k` (_ghostty_run), and the
#   CI job has its own `timeout-minutes`. The deliberate-hang case proves
#   the second of the three bites.

# Budgets (seconds) for the ghostty cases.
GHOSTTY_CLI_TIMEOUT=60      # +version / +show-config: no window at all
GHOSTTY_CHAIN_TIMEOUT=180   # one windowed run of the whole chain
GHOSTTY_HANG_TIMEOUT=45     # the deliberate-hang case: must be REACHED

# Where the chain writes its evidence. HOME is the box's bind-mounted home
# (see setup), so a file the command writes inside the box shows up here.
# NOTE: this is a SHARED mount, not a namespace the runner cannot reach -
# what makes the marker in-box evidence is that the runner has no fish (the
# preflight case asserts that), the file is removed before every launch,
# and its content is produced by fish syntax plus the box's own node name,
# which the case compares against `docker inspect dev`.
_chain_marker() { printf '%s/ghostty-chain.txt\n' "${HOME}"; }
_chain_script() { printf '%s/ghostty-chain.fish\n' "${HOME}"; }

# The deliberate-hang case's own files: a READY marker the in-box command
# writes BEFORE blocking forever, and the fish payload that does it.
_hang_ready() { printf '%s/ghostty-hang-ready.txt\n' "${HOME}"; }
_hang_script() { printf '%s/ghostty-hang.fish\n' "${HOME}"; }

# Write the fish payload the chain runs INSIDE the box: it records the fish
# version (only fish sets FISH_VERSION, and this runner has no fish at
# all), the engine's container file it sees, the mount namespace it runs
# in, whether it runs under tmux (issue #179: the terminal must start
# none), and the box's own node name.
#
# THE CONTAINER IDENTITY (issue #179 asks for /run/.containerenv; codex
# round 1 on PR #232 asks for an assertion that holds on Docker AND
# Podman). /run/.containerenv is podman's file; docker writes /.dockerenv
# instead, and distrobox itself takes either as "in a container"
# (distrobox-init). So the payload records the one it sees (ctrenv=) and
# the case requires the file of the engine in use (_engine_ctrenv). That
# alone cannot tell the box from THIS runner - a docker container itself,
# with its own /.dockerenv - so the case also requires the mount namespace
# of the engine's own pid for the dev container (`inspect --format
# '{{.State.Pid}}'`, the same template on docker and podman): a process in
# the box shares it, a process on the runner does not.
_write_chain_script() {
    cat >"$(_chain_script)" <<EOF
set -l under_tmux no
if set -q TMUX
    set under_tmux yes
end
set -l ctrenv none
for f in /run/.containerenv /.dockerenv
    if test -e \$f
        set ctrenv \$f
        break
    end
end
printf '${CHAIN_MARKER_FORMAT}' "\$FISH_VERSION" \$ctrenv (readlink /proc/self/ns/mnt) "\$under_tmux" (uname -n) \
    >$(_chain_marker)
EOF
}

# The line the chain marker must hold: fish answered, seeing a container
# file, in some mount namespace, with no tmux in between, on some node
# name (the file, the namespace and the name are compared against the
# engine and the dev container below).
CHAIN_OK='^inbox-ok fish=[0-9]+\.[0-9]+[^ ]* ctrenv=(/run/\.containerenv|/\.dockerenv) mntns=mnt:\[[0-9]+\] tmux=no host=.+$'

# The container file the engine in use writes into every container:
# podman /run/.containerenv, docker /.dockerenv.
_engine_ctrenv() {
    case "${DBX_CONTAINER_MANAGER}" in
        podman) printf '/run/.containerenv\n' ;;
        docker) printf '/.dockerenv\n' ;;
        *) fail "no container file known for engine '${DBX_CONTAINER_MANAGER}'" ;;
    esac
}

# The mount namespace of the dev container, as the engine's pid for it
# sees it from here (distrobox shares the pid namespace, so it is visible).
# `inspect --format '{{.State.Pid}}'` is the same on docker and podman.
_dev_mntns() {
    local _pid
    _pid="$(timeout -k 5 "${QUERY_TIMEOUT}" "${DBX_CONTAINER_MANAGER}" inspect dev --format '{{.State.Pid}}')"
    readlink "/proc/${_pid}/ns/mnt"
}

# Assert the chain marker exists, holds CHAIN_OK, saw the engine's own
# container file, was written in the dev container's mount namespace (not
# the runner's) and names the dev box's own hostname as the engine reports
# it - so the line cannot have been produced anywhere else on this shared
# HOME mount. $1 tags the evidence.
_assert_chain_marker_in_box() {
    local _line _marker_ns _marker_host _box_host
    assert [ -f "$(_chain_marker)" ]
    _line="$(cat "$(_chain_marker)")"
    diagnostic_lines "$1" "${_line}"
    [[ "${_line}" =~ ${CHAIN_OK} ]] \
        || fail "chain marker '${_line}' does not match ${CHAIN_OK}"
    assert_equal "$(sed -nE 's/^inbox-ok .* ctrenv=([^ ]+) .*$/\1/p' "$(_chain_marker)")" "$(_engine_ctrenv)"
    _marker_ns="$(sed -nE 's/^inbox-ok .* mntns=([^ ]+) .*$/\1/p' "$(_chain_marker)")"
    assert_equal "${_marker_ns}" "$(_dev_mntns)"
    [[ "${_marker_ns}" != "$(readlink /proc/self/ns/mnt)" ]] \
        || fail "chain marker was written in the runner's own mount namespace ${_marker_ns}"
    _marker_host="$(sed -nE 's/^inbox-ok .* host=(.+)$/\1/p' "$(_chain_marker)")"
    _box_host="$(_docker inspect dev --format '{{.Config.Hostname}}')"
    assert_equal "${_marker_host}" "${_box_host}"
    diagnostic_in_box "$1" "${_marker_ns}" "${_marker_host}"
}

# Write the fish payload of the deliberate-hang case. It announces that it
# REALLY STARTED INSIDE THE BOX first, and only then blocks forever. That
# ready marker is what separates the two ways to collect a 124: "a command
# that had begun was cut at the budget" (what this case must prove) from
# "Xvfb / GTK / ghostty / distrobox enter wedged before the box was ever
# reached" (a different bug, and a false green if accepted here).
_write_hang_script() {
    cat >"$(_hang_script)" <<EOF
printf '${HANG_READY_FORMAT}' "\$FISH_VERSION" (uname -n) >$(_hang_ready)
exec sleep infinity
EOF
}

# Write the ghostty config the case under test uses, into the throwaway
# XDG_CONFIG_HOME: the false-positive guard first, then EXACTLY ONE real
# worktool managed block (composed by the delivered lib/enter.sh, markers
# and all) holding `command = $1`. Nothing else is set - in particular
# `wait-after-command` and `quit-after-last-window-closed` keep their
# defaults, which is what makes ghostty exit on its own.
_write_ghostty_config() {
    local _file
    _file="$(enter_ghostty_target)"
    mkdir -p "$(dirname -- "${_file}")"
    printf 'gtk-single-instance = false\n' >"${_file}"
    enter_block_compose "${_file}" "command = $1" >"${_file}.new"
    mv -f "${_file}.new" "${_file}"
}

# Launch ghostty on a throwaway X server under a hard bound of $1 seconds.
# LIBGL_ALWAYS_SOFTWARE / GDK_BACKEND keep GTK on the software X11 path in
# a container with no GPU; `xvfb-run -a` picks a free display number.
# Exit status is ghostty's (124 when the bound was reached).
_ghostty_run() {
    timeout -k 5 "$1" xvfb-run -a ghostty </dev/null
}

@test "preflight: the runner has a real ghostty, Xvfb and a host tmux, and no fish of its own" {
    run timeout -k 5 "${GHOSTTY_CLI_TIMEOUT}" ghostty +version
    assert_success
    assert_line --regexp '^Ghostty [0-9]+\.[0-9]+'
    diagnostic_lines ghostty "${lines[0]}"
    run command -v xvfb-run
    assert_success
    # The chain's evidence is "fish answered". The runner must not be able
    # to produce that itself: the only fish in this container tree is the
    # box's.
    run command -v fish
    assert_failure
    # Issue #179: the host-side tmux server of section (e3) needs a tmux on
    # the runner (the "host" here).
    run tmux -V
    assert_success
    diagnostic_lines host-tmux "${lines[0]}"
}

@test "ghostty chain: the managed block pins gtk-single-instance = false (no D-Bus false positive)" {
    _write_ghostty_config "distrobox enter dev -- true"
    run env XDG_CONFIG_HOME="${XDG_CONFIG_HOME}" \
        timeout -k 5 "${GHOSTTY_CLI_TIMEOUT}" ghostty +show-config
    assert_success
    # The EFFECTIVE value, not the text on disk: `detect` must not be what
    # decides whether this window is real or forwarded to a background
    # process nobody reaps.
    assert_line 'gtk-single-instance = false'
    assert_line 'command = distrobox enter dev -- true'
}

@test "ghostty chain: a real window runs the managed block's command and leaves a marker INSIDE the box (fish, the box's mount namespace, no tmux)" {
    rm -f "$(_chain_marker)"
    _write_chain_script
    # The full chain #5 promises, in one command, but ending: ghostty ->
    # distrobox enter dev -> fish -> the marker. Issue #179: no tmux in
    # between; the script ends, `distrobox enter` returns and ghostty
    # closes the window.
    _write_ghostty_config "distrobox enter dev -- fish $(_chain_script)"
    run _ghostty_run "${GHOSTTY_CHAIN_TIMEOUT}"
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    # The witness: the file the command wrote inside the box.
    _assert_chain_marker_in_box chain
}

@test "ghostty chain: a command that has STARTED inside the box and never ends FAILS within its budget instead of hanging" {
    rm -f "$(_chain_marker)" "$(_hang_ready)"
    _write_hang_script
    # Same chain as the case above, but the in-box payload announces itself
    # and then blocks forever.
    _write_ghostty_config "distrobox enter dev -- fish $(_hang_script)"
    local _start="${SECONDS}" _elapsed _hang_status
    run _ghostty_run "${GHOSTTY_HANG_TIMEOUT}"
    _elapsed=$(( SECONDS - _start ))
    # Keep ghostty's own status: the `run cat` below would overwrite it.
    _hang_status="${status}"

    # (1) The thing being cut really was a running in-box command. Without
    # this, a 124 could just as well mean the window never opened or
    # `distrobox enter` wedged before reaching the box - a different bug,
    # and this case would be a false green.
    if [[ ! -f "$(_hang_ready)" ]]; then
        _diag
        fail "no ready marker at $(_hang_ready) after ${_elapsed}s (status ${_hang_status}): the in-box command never STARTED, so this 124 is a start-up / enter hang, not a bounded never-ending command"
    fi
    run cat "$(_hang_ready)"
    assert_success
    assert_line --regexp '^hang-ready fish=[0-9]+\.[0-9]+.* host=.+$'
    diagnostic_lines hang-ready "${lines[@]}"

    # (2) It was `timeout` that ended the run: 124 is its own "the bound
    # was reached" status, so the run was cut here and not left to the CI
    # job timeout.
    [[ "${_hang_status}" -eq 124 ]] || _diag
    assert_equal "${_hang_status}" "124"

    # (3) And it was cut AT the budget: the run lasted essentially the
    # whole budget (lower bound; `SECONDS` is integer, hence the 2s slack)
    # and did not drag on far past it (upper bound, covering the -k grace).
    assert [ "${_elapsed}" -ge $(( GHOSTTY_HANG_TIMEOUT - 2 )) ]
    assert [ "${_elapsed}" -lt $(( GHOSTTY_HANG_TIMEOUT + 30 )) ]

    # (4) The chain marker of the previous case is gone and was not
    # recreated: this payload never got past the sleep.
    assert [ ! -f "$(_chain_marker)" ]
    diagnostic_hang "${_elapsed}" "${GHOSTTY_HANG_TIMEOUT}" "${_hang_status}"
}

@test "ghostty chain: with gtk-single-instance on, a forwarded launch exits 0 while the command it asked for has not begun yet (the false positive the guard prevents)" {
    local _probe="${REPO_ROOT}/test/system/fixture/ghostty_single_instance.sh"
    run timeout -k 5 "${GHOSTTY_CHAIN_TIMEOUT}" bash "${_probe}" \
        "${BATS_TEST_TMPDIR}/si" </dev/null
    assert_success
    diagnostic_lines single-instance "${lines[@]}"
    # The fixture OBSERVES every line below; none of them is a fixed echo.
    #   The primary was really running before the second launch ...
    assert_line 'PRIMARY=up'
    #   ... the second launch reported success ...
    assert_line 'SECOND_RC=0'
    #   ... and returned far sooner than the command it asked for could
    #   ever take, since that command never ends. The threshold is
    #   generous on purpose: the claim is "did not wait for the command",
    #   not "within N seconds", and a tight number is only a way for a
    #   slow runner to go red. Measured at 0-1s.
    assert_line --regexp '^SECOND_ELAPSED=([0-9]|1[0-5])$'
    #   Read IMMEDIATELY AFTER the return (timestamp first, then the
    #   count - see the fixture header: neither is an atomic snapshot of
    #   the return instant). Still 1: the work this launch reported
    #   success for had not begun. A forwarded command fast enough to
    #   slip into that sampling gap would read 2 and fail the case, so
    #   the delay can only cost a pass, never buy one.
    assert_line 'STARTED_AT_RETURN=1'
    #   A second window command did begin ...
    assert_line 'FORWARDED_STARTED=yes'
    #   ... and its start time is MEASURED to be later than that return
    #   (mtime of its own start file vs the timestamp taken at return).
    assert_line 'FORWARDED_AFTER_RETURN=yes'
    assert_line --regexp '^FORWARDED_DELAY_MS=[1-9][0-9]*$'
    #   Both of this run's window commands are still running - asked of
    #   the command processes themselves: the pid each one recorded is
    #   present, its starttime is unchanged (so it is not a recycled pid)
    #   and it is not a zombie. `kill -0` alone would accept both of
    #   those; process-name or command-line scanning would be wrong too
    #   (the dev box's leftover sleeps share the runner's PID namespace
    #   under DinD, and `pgrep -f` matches the harness) ...
    assert_line 'RUNNING_COMMANDS=2'
    #   ... under the ghostty process that owns the bus name, which
    #   outlived the launch that "succeeded" (the wrapper, not the
    #   command's own shell - STARTED_AT_RETURN is what speaks for the
    #   command) ...
    assert_line 'PRIMARY_WRAPPER_ALIVE=yes'
    #   ... and no window command has returned at all.
    assert_line 'COMMAND_FINISHED=no'
    # That is the false positive: exit status alone is not a witness once
    # ghostty forwards over D-Bus. Which is why every case above pins
    # `gtk-single-instance = false` and judges on an in-box marker file.
}

# --- (e2) issue #175: the chain survives a desktop session's PATH ------------
#
# WHAT THIS ADDS TO THE CASES ABOVE
#   They all launch ghostty with the runner's full PATH, which holds
#   /usr/local/bin/distrobox - so a bare `distrobox` in the managed command
#   works and the real-machine bug of issue #175 is invisible. On a real
#   desktop the terminal is started by the session, inherits the systemd
#   user manager's PATH (no ~/.local/bin), and the bare name died with
#   `/bin/sh: 1: distrobox: not found`.
#
#   This case reproduces that PATH deliberately: a directory holding only
#   the container engine, plus /usr/bin:/bin - distrobox is NOT reachable
#   by name from it (the control assertion proves that first). What makes
#   the chain work anyway is the ABSOLUTE path the DELIVERED
#   script/box/setup.sh resolved into the managed block, which this case
#   reads back out of the file setup wrote.

# A PATH shaped like a desktop session's: the engine is reachable (a real
# GNOME session finds /usr/bin/docker), distrobox is not (it lives in
# /usr/local/bin here, as a user's lives in ~/.local/bin). Printed on
# stdout; the engine symlink is created under $1.
_desktop_path() {
    local _dir="$1"
    mkdir -p "${_dir}"
    ln -sf "$(command -v docker)" "${_dir}/docker"
    printf '%s:/usr/bin:/bin\n' "${_dir}"
}

@test "ghostty chain (#175): the absolute distrobox path just box setup writes enters the box from a desktop session's PATH" {
    local _setup="${REPO_ROOT}/script/box/setup.sh"
    local _gui_path _prog _ghostty_config _command
    _gui_path="$(_desktop_path "${BATS_FILE_TMPDIR}/desktop-bin")"

    # (1) The control: from that PATH, `distrobox` by name does not exist.
    # Without this the case could pass with the old bare-name command.
    run -127 env -i PATH="${_gui_path}" /bin/sh -c 'distrobox --version'
    assert_failure 127
    diagnostic_lines desktop-path "PATH=${_gui_path} has no distrobox by name"

    # (2) The DELIVERED setup.sh resolves it and writes the managed block.
    # The program is read back with the delivered decoder, so the assertion
    # travels through the same shell quoting setup.sh wrote (issue #175
    # round 1).
    run "${_setup}" --terminal ghostty --box dev
    assert_success
    _ghostty_config="$(enter_ghostty_target)"
    _prog="$(enter_body_distrobox "$(enter_block_body "${_ghostty_config}")")"
    [[ "${_prog}" == /* && -x "${_prog}" ]] \
        || fail "setup.sh wrote a command whose program is not an absolute executable: '${_prog}'"
    _command="$(enter_block_body "${_ghostty_config}")"
    run grep -qxF "command = $(enter_sh_squote "${REPO_ROOT}/script/box/enter.sh") --distrobox $(enter_sh_squote "${_prog}") --box 'dev'" \
        "${_ghostty_config}"
    assert_success
    diagnostic_lines setup-command "${_command}"

    # (3) The same distrobox program in the chain shape that ends by
    # itself, run by a real
    # ghostty window under the desktop PATH.
    rm -f "$(_chain_marker)"
    _write_chain_script
    _write_ghostty_config \
        "${_command#command = } -- fish $(_chain_script)"
    run env PATH="${_gui_path}" \
        timeout -k 5 "${GHOSTTY_CHAIN_TIMEOUT}" xvfb-run -a ghostty </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    _assert_chain_marker_in_box chain-desktop-path
}

# --- (e3) issue #179: a host tmux server must not capture the box ------------
#
# THE BUG
#   The managed command used to be `'<distrobox>' enter dev -- tmux new -A
#   -s main`. distrobox bind-mounts the host's /tmp into the box, so the
#   box's tmux found the HOST server's socket (/tmp/tmux-<uid>/default)
#   and `-A` attached to the host's `main` session: a fish prompt on the
#   host, looking like the box. CI stayed green because the runner never
#   had a tmux server of its own. These cases start one first.
#
# WHAT THEY RUN
#   (1) The command `just box setup` DELIVERS, verbatim: the window gets
#       whatever shell that command lands in, and ghostty types the payload
#       (`input`, ghostty >= 1.2) into it. If the command ever attaches to
#       the host server again, the payload runs on the runner, which has no
#       fish, and no in-box marker appears.
#   (2) `tmux` inside the box, with the host server up: the box's server
#       must be a different process, in the box's mount namespace, on a
#       socket under the box's TMUX_TMPDIR, listing only its own session.
#   (3) Entered with TMUX in the caller (a host pane): see the matrix in
#       section (e4).

# The host (runner) side tmux server and its session. `main` is the session
# the old managed command attached to (`new -A -s main`), so a regression
# would find it.
HOST_TMUX_SESSION=main

# Start a detached tmux server on the runner, with no user config and the
# default socket - the one under the shared /tmp. Prints nothing.
_host_tmux_up() {
    env -u TMUX -u TMUX_TMPDIR tmux -f /dev/null new-session -d -s "${HOST_TMUX_SESSION}"
}

# Stop the runner's tmux server. No server to stop is the expected
# non-zero here (tmux exits 1); anything else is returned.
_host_tmux_down() {
    local _rc=0
    env -u TMUX -u TMUX_TMPDIR tmux kill-server 2>/dev/null || _rc=$?
    (( _rc <= 1 )) || return "${_rc}"
}

# The pid of the runner's tmux server.
_host_tmux_pid() {
    env -u TMUX -u TMUX_TMPDIR tmux display-message -p -t "${HOST_TMUX_SESSION}" '#{pid}'
}

@test "#179 chain: with a host tmux server running, the delivered command lands in the box's fish, not on the host" {
    local _setup="${REPO_ROOT}/script/box/setup.sh" _body _file
    TMUX_CASE_ACTIVE=1
    _host_tmux_down
    _host_tmux_up
    run env -u TMUX -u TMUX_TMPDIR tmux ls
    assert_success
    assert_line --regexp "^${HOST_TMUX_SESSION}: "
    diagnostic_lines host-tmux "${lines[@]}"

    # The command exactly as the DELIVERED setup.sh writes it.
    run "${_setup}" --terminal ghostty --box dev
    assert_success
    _file="$(enter_ghostty_target)"
    _body="$(enter_block_body "${_file}")"
    [[ "${_body}" == "command = "*" --box 'dev'" ]] \
        || fail "setup.sh wrote an unexpected managed body: '${_body}'"
    diagnostic_lines setup-command "${_body}"

    # Run it, verbatim, in a real window; type the payload into whatever
    # shell it lands in.
    rm -f "$(_chain_marker)"
    _write_chain_script
    _write_ghostty_config "${_body#command = }"
    printf 'input = "raw:fish %s; exit\\n"\n' "$(_chain_script)" >>"${_file}"
    run _ghostty_run "${GHOSTTY_CHAIN_TIMEOUT}"
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    _assert_chain_marker_in_box host-tmux-chain

    # The host server is still there, untouched by the window.
    run env -u TMUX -u TMUX_TMPDIR tmux ls
    assert_success
    assert_line --regexp "^${HOST_TMUX_SESSION}: 1 windows"
    _host_tmux_down
}

@test "#179 tmux: with a host tmux server running, tmux in the box starts the box's own server (in-box pid, own socket, no host session)" {
    local _host_pid _box_pid _box_sock _box_ns _host_ns _init_ns
    TMUX_CASE_ACTIVE=1
    _host_tmux_down
    _host_tmux_up
    _host_pid="$(_host_tmux_pid)"

    # #361: assemble used a custom --home, so both the environment and
    # the real socket must follow it while retaining #179 server isolation.
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- printenv TMUX_TMPDIR </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line "${BOX_HOME}/.cache/tmux"
    assert [ ! -e "${HOME}/dev-box/.cache/tmux" ]

    # A plain `tmux`, as a user would type it, inside the box.
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- sh -c \
        'tmux -f /dev/null new-session -d -s box && tmux display-message -p -t box "#{pid} #{socket_path}" && tmux ls' </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    diagnostic_lines box-tmux "${lines[@]}"
    # It lists ITS session and not the host's.
    assert_line --regexp '^box: '
    refute_line --regexp "^${HOST_TMUX_SESSION}: "
    _box_pid="${lines[0]%% *}"
    _box_sock="${lines[0]#* }"
    # Its socket is under the box's own directory, not the shared /tmp.
    assert_equal "${_box_sock}" "${BOX_HOME}/.cache/tmux/tmux-$(id -u)/default"

    # A different server process from the host's ...
    [[ "${_box_pid}" =~ ^[0-9]+$ && "${_box_pid}" != "${_host_pid}" ]] \
        || fail "box tmux pid '${_box_pid}' is not a separate server (host pid ${_host_pid})"
    # ... running INSIDE the box: its mount namespace is the dev
    # container's (the engine's pid for it), not the runner's. distrobox
    # shares the pid namespace, so the pid is visible here.
    _init_ns="$(_dev_mntns)"
    _box_ns="$(readlink "/proc/${_box_pid}/ns/mnt")"
    _host_ns="$(readlink "/proc/${_host_pid}/ns/mnt")"
    assert_equal "${_box_ns}" "${_init_ns}"
    [[ "${_box_ns}" != "${_host_ns}" ]] || fail "box tmux server shares the host server's mount namespace (${_host_ns})"
    # ... whose filesystem holds the engine's container file.
    assert [ -e "/proc/${_box_pid}/root$(_engine_ctrenv)" ]
    diagnostic_lines box-tmux-ns "box pid=${_box_pid} mnt=${_box_ns} == dev init mnt; host pid=${_host_pid} mnt=${_host_ns}"

    # The host server still lists only its own session.
    run env -u TMUX -u TMUX_TMPDIR tmux ls
    assert_success
    assert_line --regexp "^${HOST_TMUX_SESSION}: "
    refute_line --regexp '^box: '

    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- tmux kill-server </dev/null
    assert_success
    _host_tmux_down
}

# --- (e4) issue #179: the box's tmux environment, as a matrix ---------------
#
# THE LEAK (codex rounds 1-4 on PR #232)
#   `distrobox enter` copies the caller's environment into the box. From a
#   HOST tmux pane that includes TMUX (the host server's socket, on the
#   /tmp the box shares) and TMUX_PANE, and tmux prefers the socket in
#   $TMUX over the box's TMUX_TMPDIR - whatever binary runs, so a wrapper
#   around tmux is bypassed by naming the real binary. The fix is the
#   environment: the block `just box setup` keeps in distrobox's own
#   config (distrobox-enter sources it before copying the environment)
#   drops TMUX / TMUX_PANE for the box, and the box's login shells drop a
#   host TMUX as a second line (box/tmux-env.sh, box/tmux-env.fish).
#
# THE MATRIX (equivalence classes, not examples)
#   entry path  e1 the managed ghostty command (delivered by setup.sh)
#               e2 `distrobox enter dev` (the login shell, commands on stdin)
#               e3 `distrobox enter dev -- <cmd>` (no login shell)
#               e4 `distrobox enter dev -- <real tmux> ...` (the real binary,
#                  no shell at all: the bypass codex round 4 named)
#               e5 a login shell in the box: `-- sh -l -c`, `-- fish -l -c`
#   host state  h0 no host tmux server, no TMUX in the caller
#               h1 a host tmux server running, and the caller's environment
#                  holding TMUX / TMUX_PANE for it (what a host pane has)
#   invocation  `tmux ls`, `tmux new`, `tmux new -A -s main`, `tmux attach`
#               (the last two on a terminal - script(1) - detaching at once)
#   Goal 1 of issue #179 (the terminal starts no tmux) is a check in every
#   cell: before the probe's own tmux runs, no tmux process lives in the
#   box's mount namespace, the host server (h1) has no client attached,
#   and with no host server (h0) none was started. Goal 3 (tmux config is
#   the box's, worktool never writes the host's ~/.tmux.conf) is too: a
#   sentinel ~/.tmux.conf on the host side keeps its bytes through setup.sh
#   and every cell, and the box server the cell starts (no -f) loaded its
#   config from the box's own $HOME/.tmux.conf - `#{config_files}` names
#   exactly that path. Until issue #198 gives the box its own HOME
#   (`--home`), the box's $HOME is the host HOME, so that path is the
#   sentinel itself; the assertion is on the box's $HOME, so it follows
#   the box HOME when #198 lands.
#   Every cell must see no TMUX / TMUX_PANE, list nothing before it started
#   a server (`tmux ls` with the box's server stopped: anything listed
#   would be another server's), and reach ONE server for every invocation:
#   its socket under the box's TMUX_TMPDIR, its process in the dev
#   container's mount namespace with the engine's container file under its
#   root, never the host server's pid; the host server never lists a
#   session the box made.

# The socket of the box's own server (box/dev.ini TMUX_TMPDIR).
_box_sock() { printf '%s/.cache/tmux/tmux-%s/default\n' "${BOX_HOME}" "$(id -u)"; }

# The in-box probe e1/e2/e3/e5 run: $1 is the cell tag. It prints the
# tmux environment it got and how many tmux processes already run in its
# own mount namespace (goal 1: nothing started one for it), then runs the
# four invocations with a bare `tmux` and reports the server each one
# reached and the config file that server loaded (goal 3).
_matrix_probe() { printf '%s/matrix-probe.sh\n' "${HOME}"; }
_matrix_autostart() { printf '%s/matrix-autostart.sh\n' "${HOME}"; }
_write_matrix_probe() {
    cat >"$(_matrix_autostart)" <<'EOF'
me="$(readlink /proc/self/ns/mnt)"
n=0
for p in /proc/[0-9]*; do
    c="$(cat "${p}/comm" 2>/dev/null)" || continue
    case "${c}" in
        tmux*) [ "$(readlink "${p}/ns/mnt" 2>/dev/null)" = "${me}" ] && n=$((n + 1)) ;;
    esac
done
printf '%s autostart %s\n' "$1" "${n}"
EOF
    cat >"$(_matrix_probe)" <<EOF
. $(_matrix_autostart)
EOF
    cat >>"$(_matrix_probe)" <<'EOF'
tag="$1"
printf '%s env TMUX=%s TMUX_PANE=%s\n' "${tag}" "${TMUX-}" "${TMUX_PANE-}"
if out="$(tmux ls 2>/dev/null)"; then
    printf '%s\n' "${out}" | while IFS= read -r l; do printf '%s ls %s\n' "${tag}" "${l}"; done
else
    printf '%s ls none\n' "${tag}"
fi
tmux new-session -d -s "new-${tag}" || printf '%s failed new\n' "${tag}"
tmux display-message -p -t "new-${tag}" "${tag} server new #{pid} #{socket_path}" \
    || printf '%s failed display-new\n' "${tag}"
tmux display-message -p -t "new-${tag}" "${tag} config #{config_files}|#{@worktool_cfg}" \
    || printf '%s failed display-config\n' "${tag}"
TERM=xterm script -qec 'tmux new-session -A -s main \; detach-client' /dev/null </dev/null >/dev/null 2>&1 \
    || printf '%s failed newA\n' "${tag}"
tmux display-message -p -t main "${tag} server newA #{pid} #{socket_path}" \
    || printf '%s failed display-newA\n' "${tag}"
TERM=xterm script -qec 'tmux attach-session -t main \; detach-client' /dev/null </dev/null >/dev/null 2>&1 \
    || printf '%s failed attach\n' "${tag}"
tmux display-message -p -t main "${tag} server attach #{pid} #{socket_path}" \
    || printf '%s failed display-attach\n' "${tag}"
EOF
}

# The caller environment of host state $1 (h0 / h1), as `env` arguments:
# h1 names the RUNNING host server's socket in TMUX, as tmux sets it in a
# pane (`<socket>,<server pid>,<session index>`).
_host_env() {
    case "$1" in
        h0) printf '%s\n' -u TMUX -u TMUX_PANE ;;
        h1) printf '%s\n' "TMUX=$(env -u TMUX -u TMUX_TMPDIR tmux display-message -p -t "${HOST_TMUX_SESSION}" '#{socket_path},#{pid},0')" TMUX_PANE=%0 ;;
    esac
}

# The box's own $HOME, as the box reports it.
_box_home() {
    timeout -k 5 "${ENTER_TIMEOUT}" distrobox enter dev -- printenv HOME </dev/null
}

# The real tmux binary in the box, wherever the package manager's view of
# /usr/bin/tmux really lives (a dpkg-diverted binary included).
_real_tmux() {
    timeout -k 5 "${ENTER_TIMEOUT}" distrobox enter dev -- dpkg-divert --truename /usr/bin/tmux </dev/null
}

# Goal 3's sentinel: the host side's ~/.tmux.conf (see THE MATRIX), and
# the sha256 it must keep.
_tmux_sentinel() { printf '%s/.tmux.conf\n' "${HOME}"; }
_tmux_sentinel_sum() { printf '%s/.tmux.conf.sha256\n' "${BATS_FILE_TMPDIR}"; }

# Bring host state $1 up, stop the box's server, and deliver the
# distrobox.conf block exactly as `just box setup` writes it.
_cell_prepare() {
    local _rc=0
    TMUX_CASE_ACTIVE=1
    if [[ ! -e "$(_tmux_sentinel_sum)" ]]; then
        printf 'set -g @worktool_cfg host-sentinel\n' >"$(_tmux_sentinel)"
        printf 'set -g @worktool_cfg sentinel\n' >"${BOX_HOME}/.tmux.conf"
        sha256sum <"$(_tmux_sentinel)" >"$(_tmux_sentinel_sum)"
    fi
    run "${REPO_ROOT}/script/box/setup.sh" --terminal ghostty --box dev
    assert_success
    _host_tmux_down
    [[ "$1" == "h0" ]] || _host_tmux_up
    timeout -k 5 "${ENTER_TIMEOUT}" distrobox enter dev -- "$(_real_tmux)" kill-server </dev/null >/dev/null 2>&1 || _rc=$?
    (( _rc <= 1 )) || fail "could not stop the box's tmux server (rc ${_rc})"
    _write_matrix_probe
}

# Assert the probe lines $2 of cell $1 (host state $3): see THE MATRIX.
_assert_cell() {
    local _tag="$1" _out="$2" _hs="$3" _pid="" _line _p _s _inv _host_pid=""
    local -a _ls
    mapfile -t _ls <<<"${_out}"
    diagnostic_lines "cell-${_tag}" "${_ls[@]}"
    [[ "${_hs}" == "h1" ]] && _host_pid="$(_host_tmux_pid)"
    grep -qxF "${_tag} env TMUX= TMUX_PANE=" <<<"${_out}" \
        || fail "cell ${_tag}: the box saw a TMUX / TMUX_PANE: $(grep -F "${_tag} env " <<<"${_out}")"
    grep -qxF "${_tag} ls none" <<<"${_out}" \
        || fail "cell ${_tag}: tmux ls listed another server's sessions: $(grep -F "${_tag} ls " <<<"${_out}")"
    ! grep -qF "${_tag} failed " <<<"${_out}" \
        || fail "cell ${_tag}: an invocation failed: $(grep -F "${_tag} failed " <<<"${_out}")"
    # Goal 1: nothing started a tmux for the entry before the probe did.
    grep -qxF "${_tag} autostart 0" <<<"${_out}" \
        || fail "cell ${_tag}: a tmux already ran in the box: $(grep -F "${_tag} autostart " <<<"${_out}")"
    # Goal 3: the box server loaded the box's own $HOME/.tmux.conf, and the
    # host's ~/.tmux.conf kept its bytes.
    # `#{config_files}` lists every file the server looked at (the system
    # /etc/tmux.conf and the user files under ITS $HOME); the sentinel's
    # option proves the user file it loaded was the box $HOME's.
    local _cfg _home _f
    _cfg="$(sed -nE "s/^${_tag} config //p" <<<"${_out}")"
    _home="$(_box_home)"
    [[ "${_cfg}" == *"|sentinel" ]] \
        || fail "cell ${_tag}: the box server did not load the sentinel config: ${_cfg}"
    [[ ",${_cfg%|*}," == *",${_home}/.tmux.conf,"* ]] \
        || fail "cell ${_tag}: the box server did not read ${_home}/.tmux.conf: ${_cfg}"
    local -a _files
    IFS=, read -r -a _files <<<"${_cfg%|*}"
    for _f in "${_files[@]}"; do
        [[ "${_f}" == /etc/* || "${_f}" == "${_home}/"* ]] \
            || fail "cell ${_tag}: the box server read a config outside /etc and the box HOME: ${_f}"
    done
    assert_equal "$(sha256sum <"$(_tmux_sentinel)")" "$(cat "$(_tmux_sentinel_sum)")"
    for _inv in new newA attach; do
        _line="$(grep -E "^${_tag} server ${_inv} " <<<"${_out}")" \
            || fail "cell ${_tag}: no server line for ${_inv}"
        read -r _ _ _ _p _s <<<"${_line}"
        [[ "${_p}" =~ ^[0-9]+$ ]] || fail "cell ${_tag} ${_inv}: no server pid in '${_line}'"
        [[ -z "${_pid}" || "${_p}" == "${_pid}" ]] \
            || fail "cell ${_tag} ${_inv}: reached server ${_p}, not the one of the other invocations (${_pid})"
        _pid="${_p}"
        assert_equal "${_s}" "$(_box_sock)"
        [[ "${_p}" != "${_host_pid}" ]] || fail "cell ${_tag} ${_inv}: reached the HOST server ${_p}"
    done
    assert_equal "$(readlink "/proc/${_pid}/ns/mnt")" "$(_dev_mntns)"
    assert [ -e "/proc/${_pid}/root$(_engine_ctrenv)" ]
    if [[ "${_hs}" == "h1" ]]; then
        run env -u TMUX -u TMUX_TMPDIR tmux ls -F '#{session_name}'
        assert_success
        assert_output "${HOST_TMUX_SESSION}"
        # Goal 1: no client was attached to the host server either.
        run env -u TMUX -u TMUX_TMPDIR tmux list-clients
        assert_success
        assert_output ""
    else
        # Goal 1: with no host server, none was started.
        run env -u TMUX -u TMUX_TMPDIR tmux ls
        assert_failure
    fi
    diagnostic_lines "cell-${_tag}-ok" "server pid=${_pid} socket=$(_box_sock) in the dev mount namespace"
}

# Stop whatever a #179 tmux case (the two above, a matrix cell) left
# running, pass or fail: a failed assertion skips the case's own cleanup.
teardown() {
    [[ "${TMUX_CASE_ACTIVE:-0}" == "1" ]] || return 0
    timeout -k 5 "${ENTER_TIMEOUT}" distrobox enter dev -- tmux kill-server </dev/null >/dev/null 2>&1 || :
    env -u TMUX -u TMUX_TMPDIR tmux kill-server >/dev/null 2>&1 || :
}

# Runs cell <entry> x <host state> and asserts it. e1..e5b run the probe;
# e4 runs every invocation as `distrobox enter dev -- <real tmux> ...`.
_run_cell() {
    local _e="$1" _hs="$2" _tag="$1-$2" _out _real _rc=0
    local -a _env
    _cell_prepare "${_hs}"
    mapfile -t _env < <(_host_env "${_hs}")
    case "${_e}" in
        e1)
            local _file _body _res="${HOME}/matrix-${_tag}.txt"
            _file="$(enter_ghostty_target)"
            _body="$(enter_block_body "${_file}")"
            [[ "${_body}" == "command = "*" --box 'dev'" ]] \
                || fail "setup.sh wrote an unexpected managed body: '${_body}'"
            rm -f "${_res}"
            _write_ghostty_config "${_body#command = }"
            printf 'input = "raw:sh %s %s >%s 2>&1; exit\\n"\n' "$(_matrix_probe)" "${_tag}" "${_res}" >>"${_file}"
            env "${_env[@]}" timeout -k 5 "${GHOSTTY_CHAIN_TIMEOUT}" xvfb-run -a ghostty </dev/null || _rc=$?
            [[ "${_rc}" -eq 0 ]] || { _diag; fail "cell ${_tag}: ghostty exited ${_rc}"; }
            _out="$(cat "${_res}")"
            ;;
        e2) _out="$(printf 'sh %s %s\nexit\n' "$(_matrix_probe)" "${_tag}" | env "${_env[@]}" timeout -k 5 "${ENTER_TIMEOUT}" distrobox enter dev 2>&1)" || _rc=$? ;;
        e3) _out="$(env "${_env[@]}" timeout -k 5 "${ENTER_TIMEOUT}" distrobox enter dev -- sh "$(_matrix_probe)" "${_tag}" </dev/null 2>&1)" || _rc=$? ;;
        e5a) _out="$(env "${_env[@]}" timeout -k 5 "${ENTER_TIMEOUT}" distrobox enter dev -- sh -l -c "sh $(_matrix_probe) ${_tag}" </dev/null 2>&1)" || _rc=$? ;;
        e5b) _out="$(env "${_env[@]}" timeout -k 5 "${ENTER_TIMEOUT}" distrobox enter dev -- fish -l -c "sh $(_matrix_probe) ${_tag}" </dev/null 2>&1)" || _rc=$? ;;
        e4)
            _real="$(_real_tmux)"
            diagnostic_lines "cell-${_tag}-real-tmux" "${_real}"
            _out="$(_e4_cell "${_tag}" "${_real}" "${_env[@]}")" || _rc=$?
            ;;
    esac
    # A non-zero entry is not judged by itself: the probe's own lines say
    # which invocation failed, and _assert_cell names it.
    diagnostic_lines "cell-${_tag}-rc" "${_rc}"
    _assert_cell "${_tag}" "${_out}" "${_hs}"
}

# Entry path e4: every invocation IS the distrobox command - the real
# binary $2, no shell in the box to clean anything - with the caller
# environment "${@:3}". The terminal ones run under a runner-side
# script(1), so distrobox itself allocates the box a tty. Prints the same
# lines as the probe.
_e4_cell() {
    local _tag="$1" _real="$2" _out _l
    shift 2
    local -a _dbx=(env "$@" TERM=xterm timeout -k 5 "${ENTER_TIMEOUT}" distrobox enter dev --)
    # On the terminal script(1) gives it, the command must stay in the
    # terminal's foreground process group: timeout(1) moves its child into
    # a group of its own, where the tmux client is stopped by SIGTTIN /
    # SIGTTOU for good. So the bound goes around script(1) instead.
    local -a _pty=(env "$@" TERM=xterm distrobox enter dev --)
    "${_dbx[@]}" sh "$(_matrix_autostart)" "${_tag}" </dev/null
    printf '%s env TMUX=%s TMUX_PANE=%s\n' "${_tag}" \
        "$("${_dbx[@]}" printenv TMUX </dev/null)" "$("${_dbx[@]}" printenv TMUX_PANE </dev/null)"
    if _out="$("${_dbx[@]}" "${_real}" ls </dev/null 2>/dev/null)"; then
        printf '%s\n' "${_out}" | while IFS= read -r _l; do printf '%s ls %s\n' "${_tag}" "${_l}"; done
    else
        printf '%s ls none\n' "${_tag}"
    fi
    "${_dbx[@]}" "${_real}" new-session -d -s "new-${_tag}" </dev/null || printf '%s failed new\n' "${_tag}"
    "${_dbx[@]}" "${_real}" display-message -p -t "new-${_tag}" "${_tag} server new #{pid} #{socket_path}" </dev/null \
        || printf '%s failed display-new\n' "${_tag}"
    "${_dbx[@]}" "${_real}" display-message -p -t "new-${_tag}" "${_tag} config #{config_files}|#{@worktool_cfg}" </dev/null \
        || printf '%s failed display-config\n' "${_tag}"
    timeout -k 5 "${ENTER_TIMEOUT}" script -qec "$(printf '%q ' "${_pty[@]}" "${_real}" new-session -A -s main ';' detach-client)" /dev/null </dev/null >/dev/null 2>&1 \
        || printf '%s failed newA\n' "${_tag}"
    "${_dbx[@]}" "${_real}" display-message -p -t main "${_tag} server newA #{pid} #{socket_path}" </dev/null \
        || printf '%s failed display-newA\n' "${_tag}"
    timeout -k 5 "${ENTER_TIMEOUT}" script -qec "$(printf '%q ' "${_pty[@]}" "${_real}" attach-session -t main ';' detach-client)" /dev/null </dev/null >/dev/null 2>&1 \
        || printf '%s failed attach\n' "${_tag}"
    "${_dbx[@]}" "${_real}" display-message -p -t main "${_tag} server attach #{pid} #{socket_path}" </dev/null \
        || printf '%s failed display-attach\n' "${_tag}"
}

@test "#179 matrix e1 (the managed ghostty command) x h0/h1: every tmux invocation reaches the box's own server" {
    _run_cell e1 h0
    _run_cell e1 h1
}

@test "#179 matrix e2 (distrobox enter dev, the login shell) x h0/h1: every tmux invocation reaches the box's own server" {
    _run_cell e2 h0
    _run_cell e2 h1
}

@test "#179 matrix e3 (distrobox enter dev -- <cmd>, no login shell) x h0/h1: every tmux invocation reaches the box's own server" {
    _run_cell e3 h0
    _run_cell e3 h1
}

@test "#179 matrix e4 (distrobox enter dev -- <real tmux>, no shell at all) x h0/h1: every tmux invocation reaches the box's own server" {
    _run_cell e4 h0
    _run_cell e4 h1
}

@test "#179 matrix e5 (a login shell in the box: sh -l, fish -l) x h0/h1: every tmux invocation reaches the box's own server" {
    _run_cell e5a h0
    _run_cell e5a h1
    _run_cell e5b h0
    _run_cell e5b h1
}

# The box's TMUX_TMPDIR is created by an init hook on every box start
# (box/dev.ini). `mkdir -p -m 0700` only sets the mode of a directory it
# CREATES: one that already exists with a wider mode or another owner kept
# them (codex rounds 1-4 on PR #232). The hook now sets owner and mode
# explicitly after mkdir, so a restart repairs them.
@test "#179: a box restart resets an existing TMUX_TMPDIR to the box user and mode 0700" {
    local _dir="${BOX_HOME}/.cache/tmux"
    assert [ -d "${_dir}" ]
    chmod 0755 "${_dir}"
    chown 1:1 "${_dir}"
    run stat -c '%a %u:%g' "${_dir}"
    assert_output "755 1:1"
    run timeout -k 5 "${RM_TIMEOUT}" distrobox stop -Y dev </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    run timeout -k 5 "${FIRST_ENTER_TIMEOUT}" distrobox enter dev -- true </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    run stat -c '%a %u:%g' "${_dir}"
    diagnostic_lines tmux-tmpdir-after-restart "${output}"
    assert_output "700 $(id -u):$(id -g)"
}

# --- (f) idempotency: assembling again neither errors nor duplicates ---------

@test "real engine: a second assemble.sh run exits 0 and does not duplicate the dev box" {
    cd "${REPO_ROOT}"
    run timeout "${ASSEMBLE_TIMEOUT}" "${ASSEMBLE}" </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    # Upstream's own idempotency message (distrobox-assemble): the existing
    # box is left alone, nothing is re-created.
    assert_output --partial "dev already exists"
    refute_output --partial "successfully created"
    # Issue #198: no --home given, so the recorded user choice is reused -
    # the same HOME the box has, hence no refusal.
    assert_line "[INFO] box home: ${BOX_HOME} (user)"
    run _count_named dev
    assert_output "1"
    # And it is still the same usable box.
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- rg --version </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^ripgrep [0-9]+\.[0-9]+'
}

@test "real engine (#198): assemble with a DIFFERENT --home is refused (exit 1) and the box keeps its HOME" {
    cd "${REPO_ROOT}"
    local _other="${BATS_FILE_TMPDIR}/other-home"
    run timeout "${ASSEMBLE_TIMEOUT}" "${ASSEMBLE}" --home "${_other}" </dev/null
    assert_failure 1
    assert_line --partial "[ERROR] box 'dev' already exists with HOME ${BOX_HOME}"
    assert_line "[ERROR]   distrobox rm dev"
    refute_output --partial "Creating dev"
    assert [ ! -e "${_other}" ]
    run _count_named dev
    assert_output "1"
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- printenv HOME </dev/null
    assert_success
    assert_output "${BOX_HOME}"
    run grep -x "home=${BOX_HOME}" "${XDG_CONFIG_HOME}/worktool/config"
    assert_success
}

# --- (g) teardown: distrobox rm removes the box ------------------------------

@test "real engine: distrobox rm -f dev removes the box from the engine" {
    run timeout "${RM_TIMEOUT}" distrobox rm -f dev </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    run _count_named dev
    assert_output "0"
}
