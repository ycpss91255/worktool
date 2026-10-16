#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/interrupt_load"
bats_require_minimum_version 1.5.0

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home" TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    export MATRIX_STATE="${BATS_TEST_TMPDIR}/state"
    mkdir -p "${HOME}" "${TMPDIR}" "${MATRIX_STATE}/bin"
    : >"${MATRIX_STATE}/boxes"
    export FAKE_STATE_DIR="${MATRIX_STATE}"
    install -m 755 "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${MATRIX_STATE}/bin/distrobox"
    install -m 755 "${BATS_TEST_DIRNAME}/fixture/realbox_matrix_just.sh" "${MATRIX_STATE}/bin/just"
    cat >"${MATRIX_STATE}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == 'issue view' ]]; then
    echo '[]'
else
    echo posted >>"${MATRIX_STATE}/comments"
    exit 1
fi
STUB
    chmod +x "${MATRIX_STATE}/bin/gh"
    export PATH="${MATRIX_STATE}/bin:${PATH}"
    unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME
    _copy_matrix_repo
    if [[ "${WORKTOOL_STRESS:-}" == 1 ]]; then
        interrupt_load_start
        taskset -pc "${INTERRUPT_LOAD_CPU}" "${BASHPID}" >/dev/null
    fi
}

@test "5.4: comment tags reach every child unchanged and stay absent when omitted" {
    cat >"${MATRIX_STATE}/bin/setsid" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '<%s>' "$@" >>"${MATRIX_STATE}/child-argv"
printf '\n' >>"${MATRIX_STATE}/child-argv"
exec /usr/bin/setsid "$@"
STUB
    chmod +x "${MATRIX_STATE}/bin/setsid"
    run "${REALBOX}" --allow-real-box --comment-tag '[codex]' 5.4
    assert_success
    run cat "${MATRIX_STATE}/child-argv"
    assert_success
    [ "${#lines[@]}" -eq 6 ]
    local line
    for line in "${lines[@]}"; do
        [[ "${line}" == *'<--comment-tag><[codex]>'* ]]
    done
    : >"${MATRIX_STATE}/child-argv"
    run "${REALBOX}" --allow-real-box 5.4
    assert_success
    run cat "${MATRIX_STATE}/child-argv"
    assert_success
    [ "${#lines[@]}" -eq 6 ]
    refute_output --partial '<--comment-tag>'
}

@test "5.4: all six event-driven interrupts pass with nonzero interrupted assemble" {
    run --separate-stderr "${REALBOX}" --allow-real-box 5.4
    assert_success
    local phase signal code line actual='' expected=''
    for phase in assemble bench; do
        for signal in INT TERM HUP; do
            assert_line --regexp "^interrupt ${phase} ${signal}: signal-phase=${phase} signal-after-ms=[0-9]+$"
            case "${signal}" in INT) code=130 ;; TERM) code=143 ;; HUP) code=129 ;; esac
            expected+="interrupt ${phase} ${signal}: rc=${code} cleanup-rc=0 box-gone=1 home=0 tmux=0 host-new=0 posted=0 PASS"$'\n'
        done
    done
    expected+='interrupt-matrix: PASS (6/6)'
    [ "${#lines[@]}" -eq 13 ]
    for line in "${lines[@]}"; do
        [[ "${line}" == *'signal-phase='* ]] || actual+="${line}"$'\n'
    done
    assert_equal "${actual%$'\n'}" "${expected}"
    [ ! -s "${MATRIX_STATE}/boxes" ]
    [ ! -e "${MATRIX_STATE}/comments" ]
    run find "${TMPDIR}" -name 'wt-m3-54.*' -o -name 'tmp.*'
    assert_success
    assert_output ''
}

@test "#602: a busy-host bench cell is inconclusive and never passes the matrix" {
    MATRIX_BENCH_EXIT_CELL=bench-INT MATRIX_BENCH_RC=3 \
        run "${REALBOX}" --allow-real-box 5.4
    printf '%s\n' "${output}"
    assert_failure 3
    assert_line --partial 'interrupt bench INT: INCONCLUSIVE (rc=3;'
    assert_line 'interrupt-matrix: INCONCLUSIVE (host too busy, re-run when idle)'
    refute_output --partial 'FAIL'
    refute_output --partial 'interrupt-matrix: PASS'
    assert_line --partial 'interrupt bench HUP: rc=129 cleanup-rc=0'
    [ ! -s "${MATRIX_STATE}/boxes" ]
    [ ! -e "${MATRIX_STATE}/comments" ]
    run find "${TMPDIR}" -name 'wt-m3-54.*' -o -name 'wt-m3-51.*'
    assert_success
    assert_output ''
}

@test "#602: a real bench failure after an inconclusive cell still fails the matrix" {
    sed -i "/elif \[\[ \"\${phase}\" == bench \]\]; then/a\\
    if [[ \"\${TMPDIR}/\" == */bench-TERM/* ]]; then exit 1; fi" "${MATRIX_STATE}/bin/just"
    MATRIX_BENCH_EXIT_CELL=bench-INT MATRIX_BENCH_RC=3 \
        run "${REALBOX}" --allow-real-box 5.4
    assert_failure 1
    assert_line --partial 'interrupt bench INT: INCONCLUSIVE (rc=3;'
    assert_line --partial 'interrupt bench TERM: FAIL (rc=1; cleanup-rc=0; evidence='
    assert_line 'interrupt-matrix: FAIL'
    refute_output --partial 'interrupt-matrix: INCONCLUSIVE'
    refute_output --partial 'interrupt-matrix: PASS'
    [ ! -s "${MATRIX_STATE}/boxes" ]
    [ ! -e "${MATRIX_STATE}/comments" ]
}

@test "#602: an inconclusive child cannot hide missing cleanup evidence" {
    sed -i "/^_51_cleanup() {/a\\
    if [[ \"\${TMPDIR}/\" == */bench-INT/* ]]; then return 0; fi" "${REALBOX}"
    MATRIX_BENCH_EXIT_CELL=bench-INT MATRIX_BENCH_RC=3 \
        run "${REALBOX}" --allow-real-box 5.4
    assert_failure 1
    assert_line --partial 'interrupt bench INT: FAIL (rc=3; cleanup-rc=missing; evidence='
    assert_line 'interrupt-matrix: FAIL'
    refute_output --partial 'interrupt bench INT: INCONCLUSIVE'
    refute_output --partial 'interrupt-matrix: PASS'
    [ -s "${MATRIX_STATE}/boxes" ]
    [ ! -e "${MATRIX_STATE}/comments" ]
}

@test "#601: bench starting during the box query cannot pass as assemble" {
    export MATRIX_CAPTURE_ROOT="${TMPDIR}"
    mkdir -p "${MATRIX_STATE}/original"
    mv "${MATRIX_STATE}/bin/distrobox" "${MATRIX_STATE}/original/distrobox"
    cat >"${MATRIX_STATE}/bin/distrobox" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == list && -s "${MATRIX_STATE}/boxes" ]]; then
    for capture in "${MATRIX_CAPTURE_ROOT}"/wt-m3-54.*/assemble-INT/capture; do
        printf 'phase=bench\n' >>"${capture}"
    done
fi
exec "${MATRIX_STATE}/original/distrobox" "$@"
STUB
    chmod +x "${MATRIX_STATE}/bin/distrobox"
    run "${REALBOX}" --allow-real-box 5.4
    assert_failure 1
    assert_line --partial 'interrupt assemble INT: observable event missed'
    assert_line 'interrupt-matrix: FAIL'
    refute_output --partial 'signal-phase=assemble'
    refute_output --partial 'posted=0 PASS'
    [ ! -s "${MATRIX_STATE}/boxes" ]
}

@test "#601: bench observed immediately before signalling refuses the assemble signal" {
    sed -i '/^_54_now_ms() {/a\
    if [[ -s "${MATRIX_STATE}/boxes" ]]; then\
        printf "phase=bench\\n" >>"${_54_W}/assemble-INT/capture"\
    fi' "${MATRIX_STATE}/repo/lib/realbox_interrupt.sh"
    run "${REALBOX}" --allow-real-box 5.4
    assert_failure 1
    assert_line 'interrupt-matrix: FAIL'
    refute_output --partial 'signal-phase=assemble'
    refute_output --partial 'posted=0 PASS'
    [ ! -s "${MATRIX_STATE}/boxes" ]
}

@test "#601: a bench transition at signal delivery fails with an unknown signal phase" {
    cat >>"${MATRIX_STATE}/repo/lib/realbox_interrupt.sh" <<'STUB'

# Inject the transition at delivery, after the last observer check.
kill() {
    if [[ "${1:-}" == -s && "${2:-}" == INT ]]; then
        printf 'phase=bench\n' >>"${_54_W}/assemble-INT/capture"
    fi
    builtin kill "$@"
}
STUB
    run "${REALBOX}" --allow-real-box 5.4
    assert_failure 1
    assert_line --regexp '^interrupt assemble INT: signal-phase=unknown signal-after-ms=[0-9]+$'
    assert_line --partial 'interrupt assemble INT: FAIL (rc=130; cleanup-rc=0; evidence='
    assert_line 'interrupt-matrix: FAIL'
    refute_output --partial 'signal-phase=assemble'
    refute_output --partial 'posted=0 PASS'
    [ ! -s "${MATRIX_STATE}/boxes" ]
}

@test "5.4: any cell cleanup failure fails the matrix" {
    cat >"${MATRIX_STATE}/bin/distrobox" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == rm && "${XDG_DATA_HOME}" == *"${MATRIX_FAIL_CELL}"* ]]; then
    exit 1
fi
exec "${MATRIX_STATE}/original/distrobox" "$@"
STUB
    # Preserve the basename used by the tool fixture to dispatch.
    mkdir -p "${MATRIX_STATE}/original"
    install -m 755 "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${MATRIX_STATE}/original/distrobox"
    local phase signal
    for phase in assemble bench; do
        for signal in INT TERM HUP; do
            export MATRIX_FAIL_CELL="${phase}-${signal}"
            : >"${MATRIX_STATE}/boxes"
            run "${REALBOX}" --allow-real-box 5.4
            assert_failure 1
            assert_line --partial "interrupt ${phase} ${signal}: FAIL (rc=1; cleanup-rc=1; evidence="
            assert_line 'interrupt-matrix: FAIL'
            refute_output --partial 'interrupt-matrix: PASS'
            [ -s "${MATRIX_STATE}/boxes" ]
        done
    done
}

_copy_matrix_repo() {
    local repo="${MATRIX_STATE}/repo"
    mkdir -p "${repo}"
    cp -a "${REPO_ROOT}/script" "${REPO_ROOT}/lib" "${REPO_ROOT}/box" "${repo}/"
    REALBOX="${repo}/script/verify/realbox.sh"
    sed -i 's/TIMEOUT_LONG=1800/TIMEOUT_LONG=8/; s/TIMEOUT_SHORT=180/TIMEOUT_SHORT=3/' "${REALBOX}"
}

@test "5.4: a copy without signal forwarding turns the interrupt cell red" {
    _copy_matrix_repo
    sed -i "s/verify_stop_group \"\${monitor}\" \"\${interrupted}\"/if [[ \"\${TMPDIR}\" != *\"\${FORWARDING_DEGRADE_CELL}\"* ]]; then verify_stop_group \"\${monitor}\" \"\${interrupted}\"; fi/" "${MATRIX_STATE}/repo/lib/verify_run.sh"
    local phase signal
    for phase in assemble bench; do
        for signal in INT TERM HUP; do
            export FORWARDING_DEGRADE_CELL="${phase}-${signal}"
            run "${REALBOX}" --allow-real-box 5.4
            assert_failure 1
            assert_line --partial "interrupt ${phase} ${signal}: FAIL ("
            assert_line 'interrupt-matrix: FAIL'
            refute_output --partial 'interrupt-matrix: PASS'
        done
    done
}

@test "5.4: a copy without cleanup turns every corresponding cell red" {
    _copy_matrix_repo
    sed -i "/^_51_cleanup() {/a\\    if [[ \"\${TMPDIR}\" == *\"\${CLEANUP_DEGRADE_CELL}\"* ]]; then return 0; fi" "${REALBOX}"
    local phase signal code
    for phase in assemble bench; do
        for signal in INT TERM HUP; do
            export CLEANUP_DEGRADE_CELL="${phase}-${signal}"
            : >"${MATRIX_STATE}/boxes"
            case "${signal}" in INT) code=130 ;; TERM) code=143 ;; HUP) code=129 ;; esac
            run "${REALBOX}" --allow-real-box 5.4
            assert_failure 1
            assert_line --partial "interrupt ${phase} ${signal}: FAIL (rc=${code}; cleanup-rc=missing; evidence="
            assert_line 'interrupt-matrix: FAIL'
            refute_output --partial 'interrupt-matrix: PASS'
            [ -s "${MATRIX_STATE}/boxes" ]
            local box_home
            read -r box_home <"${MATRIX_STATE}/home"
            [ -d "${box_home}/.cache/tmux" ]
        done
    done
}

@test "5.4: an unavailable capture fails before waiting for an interrupt event" {
    # Inject a filesystem failure at the external mkdir seam.
    cat >"${MATRIX_STATE}/bin/mkdir" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
/bin/mkdir "$@"
for dir in "$@"; do
    case "${dir}" in
        */wt-m3-54.*/*) /bin/mkdir "${dir}/capture" ;;
    esac
done
STUB
    chmod +x "${MATRIX_STATE}/bin/mkdir"

    run "${REALBOX}" --allow-real-box 5.4
    assert_failure 1
    assert_line --partial 'cannot create interrupt capture'
    assert_line 'interrupt assemble INT: FAIL (cannot create interrupt capture)'
    assert_line 'interrupt-matrix: FAIL'
    refute_output --partial 'observable event missed'
    refute_output --partial 'interrupt-matrix: PASS'
    [ ! -s "${MATRIX_STATE}/boxes" ]
    [ ! -e "${MATRIX_STATE}/home" ]
    [ ! -e "${MATRIX_STATE}/comments" ]
}

teardown() {
    interrupt_load_stop
    _matrix_stop_child
}

_matrix_stop_child() {
    local pid
    if [[ -f "${MATRIX_STATE}/child.pid" ]]; then
        read -r pid <"${MATRIX_STATE}/child.pid"
        # shellcheck source=lib/verify_run.sh
        source "${LIB_DIR}/verify_run.sh"
        verify_stop_group "${pid}" TERM
    fi
}

_matrix_child_stub() {
    export SIGNAL_STATE="${MATRIX_STATE}"
    cat >"${MATRIX_STATE}/child" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# A killed supervisor cannot close inherited test descriptors for us.
exec </dev/null >/dev/null 2>&1
for path in /proc/$$/fd/*; do
    fd="${path##*/}"
    if ((fd > 2)); then exec {fd}>&-; fi
done
deadline=$((SECONDS + 10))
stop_sleep() {
    if [[ -n "${!:-}" ]] && ! kill "$!" 2>/dev/null; then
        : # The background sleep may already have exited.
    fi
}
trap 'stop_sleep; exit 143' TERM
printf '%s\n' "$$" >"${SIGNAL_STATE}/child.pid"
sleep "${MATRIX_READY_DELAY:-0}"
touch "${SIGNAL_STATE}/ready"
while ((SECONDS < deadline)); do sleep 0.1 & wait "$!"; done
printf 'matrix child lifetime wait deadline exceeded\n' >&2
exit 1
STUB
    cat >"${MATRIX_STATE}/bin/setsid" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/setsid bash "${MATRIX_STATE}/child"
STUB
    chmod +x "${MATRIX_STATE}/bin/setsid"
}

@test "5.4: outer interruption records the stopped child's nonzero status" {
    _matrix_child_stub
    run node "${BATS_TEST_DIRNAME}/fixture/verify_signal.js" TERM bash \
        "${REALBOX}" --allow-real-box 5.4
    assert_success
    assert_line 'rc=143'
    assert_line '[INFO] interrupt cleanup: stopped child rc=143 (expected after termination)'
    [ ! -s "${MATRIX_STATE}/boxes" ]
    [ ! -e "${MATRIX_STATE}/comments" ]
}

@test "5.4: outer interruption during a box query keeps cleanup in the owning shell" {
    _matrix_child_stub
    sed -i '/^touch /d' "${MATRIX_STATE}/child"
    # Force the fork window before Bash resets inherited EXIT/TERM handlers.
    # Keep the pipeline producer alive until the driver signals the whole group.
    sed -i '/^    local _st=/a\\    printf "exit-shell=%s subshell=%s child=%s\\n" "${BASHPID}" "${BASH_SUBSHELL}" "${_54_PID}" >>"${MATRIX_STATE}/exits"' "${REALBOX}"
    cat >>"${MATRIX_STATE}/repo/lib/guard.sh" <<'STUB'
_matrix_list() {
    if [[ -n "${_54_PID:-}" ]]; then
        trap _on_exit EXIT
        trap 'exit 143' TERM
        touch "${SIGNAL_STATE}/ready"
        sleep 0.5
    fi
    printf '%s\n' "$1"
}
STUB
    sed -i 's/printf.*"${_out}" | awk/_matrix_list "${_out}" | awk/' "${MATRIX_STATE}/repo/lib/guard.sh"
    run node "${BATS_TEST_DIRNAME}/fixture/verify_signal.js" TERM bash \
        "${REALBOX}" --allow-real-box 5.4
    printf '%s\n' "${output}"
    cat "${MATRIX_STATE}/exits"
    assert_success
    assert_line 'rc=143'
    assert_line '[INFO] interrupt cleanup: stopped child rc=143 (expected after termination)'
    refute_output --partial 'not a child of this shell'
    refute_output --partial 'No record of process'
    refute_output --partial 'No such file or directory'
}

@test "5.4: outer interruption after child exit reuses its recorded status" {
    _matrix_child_stub
    # Let the child finish before the driver interrupts the capture validation.
    sed -i 's/^touch .*/exit 143/' "${MATRIX_STATE}/child"
    sed -i "/^_54_assert() {/a\\    touch '${SIGNAL_STATE}/ready'; sleep 0.5" "${MATRIX_STATE}/repo/lib/realbox_interrupt.sh"
    cat >>"${MATRIX_STATE}/repo/lib/guard.sh" <<'STUB'
wait() {
    local rc=0
    builtin wait "$@" || rc=$?
    printf '%s\n' "${rc}" >>"${MATRIX_STATE}/waits"
    return "${rc}"
}
STUB
    run node "${BATS_TEST_DIRNAME}/fixture/verify_signal.js" TERM bash \
        "${REALBOX}" --allow-real-box 5.4
    assert_success
    assert_line 'rc=143'
    assert_line '[INFO] interrupt cleanup: stopped child rc=143 (expected after termination)'
    run cat "${MATRIX_STATE}/waits"
    assert_output '143'
}

@test "5.4: outer interruption during status collection records the child before cleanup" {
    _matrix_child_stub
    # Interrupt the wait handoff after the child has already exited.
    sed -i 's/^touch .*/exit 143/' "${MATRIX_STATE}/child"
    cat >>"${MATRIX_STATE}/repo/lib/guard.sh" <<'STUB'
wait() {
    local rc=0
    touch "${SIGNAL_STATE}/ready"
    sleep 0.5
    builtin wait "$@" || rc=$?
    printf '%s\n' "${rc}" >>"${MATRIX_STATE}/waits"
    return "${rc}"
}
STUB
    run node "${BATS_TEST_DIRNAME}/fixture/verify_signal.js" TERM bash \
        "${REALBOX}" --allow-real-box 5.4
    assert_success
    assert_line 'rc=143'
    assert_line '[INFO] interrupt cleanup: stopped child rc=143 (expected after termination)'
    run cat "${MATRIX_STATE}/waits"
    assert_output '143'
}

@test "5.4: killed supervisor leaves no child holding the test pipe" {
    export MATRIX_READY_DELAY=6
    _matrix_child_stub
    local started="${SECONDS}"
    run node "${BATS_TEST_DIRNAME}/fixture/verify_signal.js" TERM bash \
        "${REALBOX}" --allow-real-box 5.4
    assert_success
    assert_line 'rc=137'
    local pid path target parent group session state rest row
    read -r pid <"${MATRIX_STATE}/child.pid"
    # Inspect before teardown can signal the orphan. Bash may keep its script fd.
    for path in /proc/"${pid}"/fd/*; do
        if ! target="$(readlink "${path}")"; then continue; fi
        [[ "${target}" != pipe:* ]]
    done
    # shellcheck source=lib/verify_run.sh
    source "${LIB_DIR}/verify_run.sh"
    while verify_group_running "${pid}" && ((SECONDS - started < 14)); do
        sleep 0.05
    done
    run verify_group_running "${pid}"
    assert_failure 1
    [ "$((SECONDS - started))" -lt 14 ]
    # Include descendants in other process groups within the child's session.
    for path in /proc/[0-9]*/stat; do
        if ! IFS= read -r row 2>/dev/null <"${path}"; then continue; fi
        read -r state parent group session rest <<<"${row##*) }"
        if [[ "${session}" == "${pid}" && "${parent}" == 1 ]]; then
            [[ "${state}" == Z || "${state}" == X ]]
        fi
    done
}

@test "5.4: a preexisting box reports the refused cell and remains untouched" {
    printf 'dev\n' >"${MATRIX_STATE}/boxes"
    run "${REALBOX}" --allow-real-box 5.4
    assert_failure 1
    assert_line 'interrupt assemble INT: FAIL (preexisting box refused or box query failed)'
    assert_line 'interrupt-matrix: FAIL'
    assert_equal "$(cat "${MATRIX_STATE}/boxes")" dev
    [ ! -e "${MATRIX_STATE}/home" ]
    [ ! -e "${MATRIX_STATE}/comments" ]
}

@test "5.4: a failed initial comment snapshot reports the cell before starting" {
    cat >"${MATRIX_STATE}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo '[]'
exit 1
STUB
    run "${REALBOX}" --allow-real-box 5.4
    assert_failure 1
    assert_line 'interrupt assemble INT: FAIL (cannot snapshot issue comments)'
    assert_line 'interrupt-matrix: FAIL'
    [ ! -s "${MATRIX_STATE}/boxes" ]
    [ ! -e "${MATRIX_STATE}/home" ]
}

@test "5.4: changed comment IDs fail the cell even with successful cleanup" {
    cat >"${MATRIX_STATE}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ -e "${MATRIX_STATE}/snapshot-taken" ]]; then
    echo '["new-comment-id"]'
else
    touch "${MATRIX_STATE}/snapshot-taken"
    echo '[]'
fi
STUB
    run "${REALBOX}" --allow-real-box 5.4
    assert_failure 1
    assert_line --partial 'interrupt assemble INT: FAIL (rc=130; cleanup-rc=0; evidence='
    assert_line 'interrupt-matrix: FAIL'
    refute_output --partial 'interrupt-matrix: PASS'
    [ ! -s "${MATRIX_STATE}/boxes" ]
}

@test "5.4: a posted capture line fails the cell even with unchanged comment IDs" {
    mkdir -p "${MATRIX_STATE}/original"
    install -m 755 "${BATS_TEST_DIRNAME}/fixture/realbox_matrix_just.sh" "${MATRIX_STATE}/original/just"
    cat >"${MATRIX_STATE}/bin/just" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${2:-}" == assemble ]]; then
    echo 'posted=1 comment=unexpected' >&2
fi
exec "${MATRIX_STATE}/original/just" "$@"
STUB
    run "${REALBOX}" --allow-real-box 5.4
    assert_failure 1
    assert_line 'posted=1 comment=unexpected'
    assert_line --partial 'interrupt assemble INT: FAIL (rc=130; cleanup-rc=0; evidence='
    assert_line 'interrupt-matrix: FAIL'
    refute_output --partial 'interrupt-matrix: PASS'
    [ ! -s "${MATRIX_STATE}/boxes" ]
    [ ! -e "${MATRIX_STATE}/comments" ]
}

@test "5.4: a missing observable event fails within the unit deadline" {
    _matrix_child_stub
    sed -i 's/SECONDS + 10/SECONDS + 30/' "${MATRIX_STATE}/child"
    local started="${SECONDS}"
    run timeout --kill-after=1 12 "${REALBOX}" --allow-real-box 5.4
    assert_failure 1
    assert_line --partial 'interrupt assemble INT: observable event missed'
    assert_line 'interrupt-matrix: FAIL'
    [ "$((SECONDS - started))" -lt 12 ]
}

@test "5.4: a failed observer cannot leave the cell waiting forever for its child" {
    _matrix_child_stub
    sed -i "s/^trap .* TERM$/trap '' TERM/" "${MATRIX_STATE}/child"
    sed -i '/^_54_poll() {/a\    return 1' "${MATRIX_STATE}/repo/lib/realbox_interrupt.sh"
    run timeout --kill-after=1 8 "${REALBOX}" --allow-real-box 5.4
    assert_failure 1
    assert_line --partial 'interrupt assemble INT: child reap wait deadline exceeded'
    assert_line 'interrupt-matrix: FAIL'
}

@test "5.4: outer cleanup bounds the wait for a TERM-ignoring child" {
    _matrix_child_stub
    sed -i "s/^trap .* TERM$/trap '' TERM/" "${MATRIX_STATE}/child"
    run node "${BATS_TEST_DIRNAME}/fixture/verify_signal.js" TERM bash \
        "${REALBOX}" --allow-real-box 5.4
    assert_success
    assert_line 'rc=1'
    assert_line --partial 'interrupt cleanup: child reap wait deadline exceeded'
}

@test "5.4: TERM at the EXIT handoff still completes bounded outer cleanup" {
    _matrix_child_stub
    sed -i "s/^trap .* TERM$/trap '' TERM/" "${MATRIX_STATE}/child"
    # Pin a second TERM to entry into EXIT cleanup, before its first command.
    sed -i '/^_on_exit() {/a\    builtin kill -TERM "${BASHPID}"' "${REALBOX}"
    run node "${BATS_TEST_DIRNAME}/fixture/verify_signal.js" TERM bash \
        "${REALBOX}" --allow-real-box 5.4
    printf '%s\n' "${output}"
    assert_success
    assert_line 'rc=1'
    assert_line --partial 'interrupt cleanup: child reap wait deadline exceeded'
}

@test "5.4: matrix fixture residents expire without supervisor signals" {
    local phase
    for phase in assemble bench; do
        mkdir -p "${TMPDIR}/assemble-INT/cell"
        run timeout --kill-after=1 5 env MATRIX_FIXTURE_TIMEOUT=1 \
            TMPDIR="${TMPDIR}/assemble-INT/cell" bash \
            "${BATS_TEST_DIRNAME}/fixture/realbox_matrix_just.sh" --yes "${phase}" "${HOME}/box"
        assert_failure 1
        assert_line --partial "matrix fixture ${phase}: resident wait deadline exceeded"
    done
}

@test "5.4: removing matrix evidence remains part of successful cleanup" {
    cat >"${MATRIX_STATE}/bin/rm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
target="${*: -1}"
if [[ "${target##*/}" == wt-m3-54.* ]]; then exit 1; fi
exec /bin/rm "$@"
STUB
    chmod +x "${MATRIX_STATE}/bin/rm"
    run "${REALBOX}" --allow-real-box 5.4
    assert_failure 1
    refute_output --partial 'interrupt-matrix: PASS'
}
