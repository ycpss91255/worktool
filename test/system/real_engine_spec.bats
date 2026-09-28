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
#   All three metric lines (enter, shell, and since issue #162 inbox: the
#   shell start-up clocked INSIDE the box by a bash timer, which proves the
#   in-box timer really prints a number on a real box) are still echoed
#   into the TAP stream as evidence. A negative case runs the same bench
#   with `--max-ms 1` and requires exit 1 plus bench.sh's threshold
#   message, so the gate is proven to bite on a real box - a green positive
#   case can never be a no-op threshold. The runtime decision (docker +
#   default runc stays; CI measured ~88 ms) is recorded in issue #22.
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

# Assert that the last `run` printed all three bench.sh metric lines
# (stdout); they must appear whether the threshold passed or not. The inbox
# line is the one that can only be produced by a timer that really ran
# inside the box and printed an integer (bench.sh aborts otherwise).
_assert_metric_lines() {
    assert_line --regexp "^enter: min=${BENCH_NUM} median=${BENCH_NUM} max=${BENCH_NUM} ms$"
    assert_line --regexp "^shell: min=${BENCH_NUM} median=${BENCH_NUM} max=${BENCH_NUM} ms$"
    assert_line --regexp "^inbox: min=${BENCH_NUM} median=${BENCH_NUM} max=${BENCH_NUM} ms$"
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
#   primary instance over D-Bus to open the window and exits 0 immediately -
#   so exit 0 proves nothing about the command. The test config therefore
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

@test "ghostty chain: with gtk-single-instance on, a forwarded launch exits 0 while the command it asked for is still only starting elsewhere (the false positive the guard prevents)" {
    local _probe="${REPO_ROOT}/test/system/fixture/ghostty_single_instance.sh"
    run timeout -k 5 "${GHOSTTY_CHAIN_TIMEOUT}" bash "${_probe}" \
        "${BATS_TEST_TMPDIR}/si" </dev/null
    assert_success
    _log_lines single-instance "${lines[@]}"
    # The fixture OBSERVES each of these; none of them is a fixed echo.
    #   the primary was really running before the second launch ...
    assert_line 'PRIMARY=up'
    #   ... the second launch reported success ...
    assert_line 'SECOND_RC=0'
    #   ... it returned at once (a real launch blocks until its window
    #   closes; 0-5s is "did not wait for anything") ...
    assert_line --regexp '^SECOND_ELAPSED=[0-5]$'
    #   ... yet a SECOND window command only began afterwards ...
    assert_line 'FORWARDED_STARTED=yes'
    #   ... in the primary, which outlived the launch that "succeeded" ...
    assert_line 'PRIMARY_ALIVE=yes'
    #   ... and no window command has returned at all.
    assert_line 'COMMAND_FINISHED=no'
    # That is the false positive: exit status alone is not a witness once
    # ghostty forwards over D-Bus. Which is why every case above pins
    # `gtk-single-instance = false` and judges on an in-box marker file.
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
    run _count_named dev
    assert_output "1"
    # And it is still the same usable box.
    run timeout "${ENTER_TIMEOUT}" distrobox enter dev -- rg --version </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    assert_line --regexp '^ripgrep [0-9]+\.[0-9]+'
}

# --- (g) teardown: distrobox rm removes the box ------------------------------

@test "real engine: distrobox rm -f dev removes the box from the engine" {
    run timeout "${RM_TIMEOUT}" distrobox rm -f dev </dev/null
    [[ "${status}" -eq 0 ]] || _diag
    assert_success
    run _count_named dev
    assert_output "0"
}
