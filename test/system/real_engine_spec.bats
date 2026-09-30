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
#   M3 (issue #198) gives the box its own HOME: the first assemble passes
#   `--home BOX_HOME`, and a case asserts that `$HOME` INSIDE the real box
#   is exactly that path (and DISTROBOX_HOST_HOME the runner's HOME). The
#   second assemble, without --home, reuses the recorded user choice; a
#   third one with a DIFFERENT --home is refused with exit 1 and leaves the
#   box and its HOME as they were. Issue #199: that first assemble also
#   links the host user config (~/.ssh, ~/.gitconfig) into BOX_HOME, and a
#   case reads it back at `$HOME` INSIDE the box.
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
#   M3 (issue #180): the FIRST enter runs through the delivered entry
#   wrapper script/box/enter.sh (what the managed terminal command runs),
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

# M3 (issue #180): the FIRST enter goes through the delivered entry wrapper
# `script/box/enter.sh`, exactly as the managed terminal command does, so a
# real first initialisation is observable: stderr carries the first-launch
# notice, the host log path and progress lines (the interval is shortened
# to 5 s so even a fast CI init shows several), and the host log exists
# and holds the init output. The progress lines go into the TAP stream as
# evidence.
@test "real engine: enter.sh --box dev -- rg --version shows first-launch progress and the host log, then prints a ripgrep version" {
    cd "${REPO_ROOT}"
    local _log="${HOME}/.cache/worktool/dev-init.log"
    run _docker inspect --type container -f '{{.State.StartedAt}}' dev
    assert_success
    assert_output --regexp '^0001-01-01'
    WORKTOOL_INIT_INTERVAL=5 run timeout "${FIRST_ENTER_TIMEOUT}" \
        "${ENTER}" --box dev --timeout "${FIRST_ENTER_TIMEOUT}" -- rg --version </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^ripgrep [0-9]+\.[0-9]+'
    assert_output --partial "first launch of box 'dev'"
    assert_output --partial "full init log: ${_log}"
    assert_line --regexp '^\[INFO\] first launch: .+ - [0-9m]+s elapsed - '
    assert_line --regexp 'first launch: initialisation complete after '
    local _first=()
    mapfile -t _first < <(printf '%s\n' "${lines[@]}" | grep -F 'first launch')
    _log_lines first-launch "${_first[@]}"
    assert [ -s "${_log}" ]
    run grep -c 'container_setup_done' "${_log}"
    assert_success
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

# --- (c2) the box's own HOME (issue #198) -------------------------------------

@test "real engine (#198): \$HOME inside the box is the path assemble --home asked for" {
    # printenv prints the two values in the order asked, one per line.
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- \
        printenv HOME DISTROBOX_HOST_HOME </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_equal "${lines[0]}" "${BOX_HOME}"
    assert_equal "${lines[1]}" "${HOME}"
    _log_lines box-home "${lines[@]}"
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
    _log_lines link "${lines[@]}"
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
    assert_line --regexp "^\[INFO\] shell: ${_warmup} warmup \+ ${_runs} run\(s\) of 'distrobox enter dev -- ${BENCH_SHELL}' done$"
    assert_line --regexp "^\[INFO\] inbox: ${_warmup} warmup \+ ${_runs} run\(s\) of 'distrobox enter dev -- bash -c <timer> bench-inbox ${BENCH_SHELL}' done$"
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
    _log_lines bench "${lines[@]}"
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
    _log_lines bench-gate "${lines[@]}"
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
# all), whether it is running under tmux, and the box's own node name.
_write_chain_script() {
    cat >"$(_chain_script)" <<EOF
set -l under_tmux no
if set -q TMUX
    set under_tmux yes
end
printf 'inbox-ok fish=%s tmux=%s host=%s\n' "\$FISH_VERSION" "\$under_tmux" (uname -n) \
    >$(_chain_marker)
EOF
}

# Write the fish payload of the deliberate-hang case. It announces that it
# REALLY STARTED INSIDE THE BOX first, and only then blocks forever. That
# ready marker is what separates the two ways to collect a 124: "a command
# that had begun was cut at the budget" (what this case must prove) from
# "Xvfb / GTK / ghostty / distrobox enter wedged before the box was ever
# reached" (a different bug, and a false green if accepted here).
_write_hang_script() {
    cat >"$(_hang_script)" <<EOF
printf 'hang-ready fish=%s host=%s\n' "\$FISH_VERSION" (uname -n) >$(_hang_ready)
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
    _file="$(enter_ghostty_config)"
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

@test "preflight: the runner has a real ghostty and Xvfb, and no fish of its own" {
    run timeout -k 5 "${GHOSTTY_CLI_TIMEOUT}" ghostty +version
    assert_success
    assert_line --regexp '^Ghostty [0-9]+\.[0-9]+'
    _log_lines ghostty "${lines[0]}"
    run command -v xvfb-run
    assert_success
    # The chain's evidence is "fish answered". The runner must not be able
    # to produce that itself: the only fish in this container tree is the
    # box's.
    run command -v fish
    assert_failure
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

@test "ghostty chain: a real window runs the managed block's command and leaves a marker INSIDE the box (fish under tmux)" {
    rm -f "$(_chain_marker)"
    _write_chain_script
    # The full chain #5 promises, in one command, but ending: ghostty ->
    # distrobox enter dev -> tmux -> fish -> the marker. `tmux new -A -s`
    # is the delivered shape; the session ends when the script does, so
    # tmux exits, `distrobox enter` returns and ghostty closes the window.
    _write_ghostty_config \
        "distrobox enter dev -- tmux new -A -s chain fish $(_chain_script)"
    run _ghostty_run "${GHOSTTY_CHAIN_TIMEOUT}"
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    # The witness: the file the command wrote inside the box.
    assert [ -f "$(_chain_marker)" ]
    run cat "$(_chain_marker)"
    assert_success
    assert_line --regexp '^inbox-ok fish=[0-9]+\.[0-9]+.* tmux=yes host=.+$'
    _log_lines chain "${lines[@]}"

    # The node name in the marker must be the dev box's own, as the engine
    # reports it - so the line cannot have been produced anywhere else on
    # this shared HOME mount.
    local _marker_host _box_host
    _marker_host="$(sed -nE 's/^inbox-ok .* host=(.+)$/\1/p' "$(_chain_marker)")"
    run _docker inspect dev --format '{{.Config.Hostname}}'
    assert_success
    _box_host="${output}"
    assert_equal "${_marker_host}" "${_box_host}"
    _log_lines chain-host "marker host=${_marker_host} == docker inspect dev hostname"
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
    _log_lines hang-ready "${lines[@]}"

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
    _log_lines hang "in-box command started, then timed out after ${_elapsed}s (budget ${GHOSTTY_HANG_TIMEOUT}s, status ${_hang_status})"
}

@test "ghostty chain: with gtk-single-instance on, a forwarded launch exits 0 while the command it asked for has not begun yet (the false positive the guard prevents)" {
    local _probe="${REPO_ROOT}/test/system/fixture/ghostty_single_instance.sh"
    run timeout -k 5 "${GHOSTTY_CHAIN_TIMEOUT}" bash "${_probe}" \
        "${BATS_TEST_TMPDIR}/si" </dev/null
    assert_success
    _log_lines single-instance "${lines[@]}"
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
    local _gui_path _prog _ghostty_config
    _gui_path="$(_desktop_path "${BATS_FILE_TMPDIR}/desktop-bin")"

    # (1) The control: from that PATH, `distrobox` by name does not exist.
    # Without this the case could pass with the old bare-name command.
    run -127 env -i PATH="${_gui_path}" /bin/sh -c 'distrobox --version'
    assert_failure 127
    _log_lines desktop-path "PATH=${_gui_path} has no distrobox by name"

    # (2) The DELIVERED setup.sh resolves it and writes the managed block.
    # The program is read back with the delivered decoder, so the assertion
    # travels through the same shell quoting setup.sh wrote (issue #175
    # round 1).
    run "${_setup}" --terminal ghostty --box dev
    assert_success
    _ghostty_config="$(enter_ghostty_config)"
    _prog="$(enter_body_distrobox "$(enter_block_body "${_ghostty_config}")")"
    [[ "${_prog}" == /* && -x "${_prog}" ]] \
        || fail "setup.sh wrote a command whose program is not an absolute executable: '${_prog}'"
    run grep -qxF "command = $(enter_sh_squote "${ENTER}") --distrobox $(enter_sh_squote "${_prog}") --box dev -- tmux new -A -s main" \
        "${_ghostty_config}"
    assert_success
    _log_lines setup-command "command = $(enter_sh_squote "${ENTER}") --distrobox $(enter_sh_squote "${_prog}") --box dev -- tmux new -A -s main"

    # (3) The same command - the entry wrapper (issue #180) naming that
    # program - in the chain shape that ends by itself, run by a real
    # ghostty window under the desktop PATH.
    rm -f "$(_chain_marker)"
    _write_chain_script
    _write_ghostty_config \
        "$(enter_sh_squote "${ENTER}") --distrobox $(enter_sh_squote "${_prog}") --box dev -- tmux new -A -s chain175 fish $(_chain_script)"
    run env PATH="${_gui_path}" \
        timeout -k 5 "${GHOSTTY_CHAIN_TIMEOUT}" xvfb-run -a ghostty </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert [ -f "$(_chain_marker)" ]
    run cat "$(_chain_marker)"
    assert_success
    assert_line --regexp '^inbox-ok fish=[0-9]+\.[0-9]+.* tmux=yes host=.+$'
    _log_lines chain-desktop-path "${lines[@]}"
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
