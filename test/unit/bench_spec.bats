#!/usr/bin/env bats
# test/unit/bench_spec.bats - script/box/bench.sh enter-latency measurement
# and CLI (M3, issues #150, #162 and #181)
#
# Written test-first (RED) before the tool exists, then bench.sh is
# implemented to pass (GREEN). #162 adds the third metric (inbox) and the
# --box / --shell validation that keeps --json valid JSON, again test-first.
#
# Contract under test:
#   - Three metrics, in this order:
#       enter = `<managed-command> -- true`          host EPOCHREALTIME
#       shell = `<managed-command> -- <shell>`       host EPOCHREALTIME
#               (default `sh -c :`)
#       inbox = `<managed-command> -- bash -c '<timer>' bench-inbox <shell>`
#               where <timer> runs <shell> INSIDE the box between two in-box
#               EPOCHREALTIME reads and prints the difference (microseconds,
#               one integer, last stdout line); the enter round trip is NOT
#               part of this number.
#     Every metric runs --warmup unrecorded times, then --runs recorded
#     times (defaults: box dev, runs 10, warmup 2).
#   - Plain text on stdout, one line per metric, nothing else:
#       enter: min=<ms> median=<ms> max=<ms> ms
#       shell: min=<ms> median=<ms> max=<ms> ms
#       inbox: min=<ms> median=<ms> max=<ms> ms
#     with min <= median <= max and the warmup runs excluded from the
#     statistics. --json replaces the three lines with ONE JSON object that
#     is ALWAYS valid JSON: --box must match ^[A-Za-z0-9._-]+$ and --shell
#     must not contain a control character (newline, tab, ...); anything
#     else is refused with `bench.sh: invalid --box ... (see --help)` /
#     `bench.sh: invalid --shell ... (see --help)` on stderr, exit 2, before
#     anything runs. A backslash or double quote in --shell is legal and
#     escaped in shell_cmd.
#   - --max-ms N: exit 1 when the SHELL median exceeds N ms (the numbers
#     are still printed; the reason goes to stderr), exit 0 otherwise.
#   - The tool owns its CLI: `--help` / `-h` print usage and exit 0 after
#     the WHOLE command line was parsed; an unknown option is refused with
#     `bench.sh: unknown option '<x>' (see --help)` on stderr, exit 2,
#     nothing on stdout, and distrobox is never called; a bad --runs /
#     --warmup / --max-ms value is refused the same way (exit 2).
#   - A distrobox run that exits non-zero aborts the measurement (exit 1,
#     no statistics line), whichever metric it belongs to; an in-box timer
#     that prints something other than an integer aborts the same way; a
#     missing distrobox is exit 127.
#   - Quiet-host precondition (issue #181): before the first run, CPU
#     pressure (PSI) `some avg10 <= 2.00` must hold for 5 consecutive
#     seconds (one poll a second); not within --max-wait seconds (default
#     60, 120 when CI is set) -> exit 3 "host too busy to measure
#     (inconclusive)", distrobox never called, nothing on stdout. PSI is
#     read again and recorded (one stderr line each) before and after
#     every run, a failed run included; one reading above the limit
#     (exact at any precision: 2.001 is above 2.00) voids the whole batch
#     -> exit 3, no metric line, even when that run also failed. No readable PSI ->
#     a warning and an unguarded measurement. The PSI source is the
#     process's own cgroup v2 cpu.pressure, then /proc/pressure/cpu.
#
# HOW
#   A FAKE `distrobox` sits first on PATH. It records every call (one line
#   `$*` per call, and `$#` per call in a sibling file) and takes a
#   configurable number of milliseconds: FAKE_DBX_SLEEP_MS for every call;
#   FAKE_DBX_SLEEP_MS_LIST instead gives the k-th call with an identical
#   argv the k-th entry (cycling), so one metric's warmup can be slow and
#   its runs fast, which makes the "warmup excluded" claim checkable;
#   FAKE_DBX_SLEEP_MS_TRUE overrides the time for the `-- true` argv only
#   (the enter metric), so the metrics can differ; FAKE_DBX_MS_ENTER,
#   FAKE_DBX_MS_SHELL and FAKE_DBX_MS_INBOX override everything for their
#   own metric with a per-metric list (cycling like FAKE_DBX_SLEEP_MS_LIST),
#   which is how the threshold matrix gives one metric its samples. FAKE_DBX_EXIT injects a
#   failing enter for every call; FAKE_DBX_EXIT_SHELL only for the shell
#   argv and FAKE_DBX_EXIT_INBOX only for the inbox argv, so "enter passes,
#   a later metric fails" is testable.
#
#   Time is FAKE (issue #249): the fake distrobox never really sleeps, it
#   ADVANCES a fake clock (FAKE_CLOCK_FILE, microseconds) by the time it was
#   told to take, and bench.sh reads its host clock from that file through
#   BENCH_CLOCK (its test-only clock program, see _install_fake_clock). So
#   every host-clocked sample is EXACTLY the injected time and no verdict
#   depends on how loaded the host running this spec is. Real wall-clock
#   timing is left to the system-real gate (test/system/real_engine_spec.bats),
#   which has its own load guard (exit 3, doc/adr/0003-latency-gate-inconclusive.md).
#
#   The fake understands the inbox argv (`-- bash -c <timer> ...`, told
#   apart by the EPOCHREALTIME reads in the timer text): it does NOT run the
#   timer, it advances the fake clock like any other call and then prints
#   the microseconds it was told to take (FAKE_DBX_INBOX_OUT replaces that
#   line verbatim, to inject garbage). So the inbox numbers are INJECTED,
#   not measured on the host: the fake's stdout is exactly what a real
#   in-box timer prints. With the fake clock every metric - inbox and the
#   host-clocked enter / shell alike - is asserted EXACTLY. Whether the real
#   timer prints what the fake prints is the system-real gate's business
#   (test/system/real_engine_spec.bats).
#
#   The quiet-host wait is driven by BENCH_PSI_FILE (bench.sh's test-only
#   PSI path) and a FAKE `sleep` first on PATH (see _install_fake_sleep):
#   the wait costs no real time and every poll is counted, and the fake
#   distrobox can turn the host busy mid-batch (FAKE_DBX_PSI_AT). setup()
#   starts every case on a quiet fake PSI, so the real host's load never
#   decides a unit verdict.

load "${BATS_TEST_DIRNAME}/../helper/common"

# `run -127` below (bats-core >= 1.5.0) needs this guard or bats-core warns
# BW02 instead. Both bats sources this repo uses are already well above
# 1.5.0 (dockerfile/Dockerfile.test: bats/bats:latest; Dockerfile.system-real:
# BATS_TAG=1.14.0), so this only documents the requirement.
bats_require_minimum_version 1.5.0

setup() {
    BENCH="${REPO_ROOT}/script/box/bench.sh"
    TMP="${BATS_TEST_TMPDIR}"
    MOCKBIN="${TMP}/bin"
    export FAKE_DBX_CALLS="${TMP}/distrobox.calls"
    export FAKE_SLEEP_CALLS="${TMP}/sleep.calls"
    # The host clock bench.sh reads is the fake one (issue #249): it only
    # moves when the fake distrobox says a run took time.
    export FAKE_CLOCK_FILE="${TMP}/clock.us"
    export BENCH_CLOCK="${MOCKBIN}/fake-clock"
    # Every case measures on a QUIET fake PSI unless it says otherwise:
    # the host this spec runs on must never decide a unit verdict.
    export BENCH_PSI_FILE="${TMP}/cpu.pressure"
    _psi 0.00
    _install_fake_distrobox
    _install_fake_sleep
    _install_fake_clock
    _install_cpu_load
    PATH="${MOCKBIN}:${PATH}"
}

# Write a PSI cpu.pressure file whose `some avg10` is $1 (to $2, default
# BENCH_PSI_FILE), in the kernel's own two-line format.
_psi() {
    printf 'some avg10=%s avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' \
        "$1" >"${2:-${BENCH_PSI_FILE}}"
}

# A fake `sleep` first on PATH: bench.sh's quiet-host wait polls PSI once a
# second with `sleep 1`, so the fake makes the wait instant and COUNTABLE
# (one line per call, its argv, in FAKE_SLEEP_CALLS). With FAKE_PSI_SEQ
# set, the k-th call rewrites BENCH_PSI_FILE with the k-th value of the
# list (the last one sticks): the host "changes" between two polls.
_install_fake_sleep() {
    cat >"${MOCKBIN}/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_SLEEP_CALLS}"
if [[ -n "${FAKE_PSI_SEQ:-}" ]]; then
    read -r -a _seq <<<"${FAKE_PSI_SEQ}"
    _k="$(wc -l <"${FAKE_SLEEP_CALLS}")"
    _i=$(( _k - 1 ))
    (( _i < ${#_seq[@]} )) || _i=$(( ${#_seq[@]} - 1 ))
    printf 'some avg10=%s avg60=0.00 avg300=0.00 total=1\n' "${_seq[_i]}" >"${BENCH_PSI_FILE}"
fi
exit 0
EOF
    chmod +x "${MOCKBIN}/sleep"
}

# Number of `sleep` calls bench.sh made (each one is one second of wait).
_sleeps() {
    if [[ -f "${FAKE_SLEEP_CALLS}" ]]; then
        wc -l <"${FAKE_SLEEP_CALLS}" | tr -d ' '
    else
        printf '0\n'
    fi
}

# The fake clock bench.sh runs as BENCH_CLOCK: it prints the fake time in
# microseconds (FAKE_CLOCK_FILE, started at an arbitrary epoch), which only
# the fake distrobox advances.
_install_fake_clock() {
    printf '1700000000000000\n' >"${FAKE_CLOCK_FILE}"
    cat >"${MOCKBIN}/fake-clock" <<'EOF'
#!/usr/bin/env bash
cat "${FAKE_CLOCK_FILE}"
EOF
    chmod +x "${MOCKBIN}/fake-clock"
}

# A bounded CPU worker, used only inside the test container. timeout owns
# the process group so an interrupted fixture cannot leave a busy loop behind.
# Publish ready before the deadline starts, even if the child never gets CPU time.
_install_cpu_load() {
    cat >"${MOCKBIN}/cpu-load" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ready\n' >"$2"
rc=0
timeout "$1" bash -c 'while :; do :; done' || rc=$?
if (( rc == 124 )); then
    exit 0
fi
exit "${rc}"
EOF
    chmod +x "${MOCKBIN}/cpu-load"
}

# The fake distrobox described in the header.
_install_fake_distrobox() {
    mkdir -p "${MOCKBIN}"
    cat >"${MOCKBIN}/distrobox" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$#" >>"${FAKE_DBX_CALLS}.argc"
printf '%s\n' "$*" >>"${FAKE_DBX_CALLS}"
_kind=shell
[[ "$*" == *" -- true" ]] && _kind=enter
[[ "$*" == *" -- bash -c "*EPOCHREALTIME* ]] && _kind=inbox
_ms="${FAKE_DBX_SLEEP_MS:-0}"
if [[ -n "${FAKE_DBX_SLEEP_MS_LIST:-}" ]]; then
    read -r -a _list <<<"${FAKE_DBX_SLEEP_MS_LIST}"
    _k="$(grep -c -x -F -- "$*" "${FAKE_DBX_CALLS}")"
    _ms="${_list[$(( (_k - 1) % ${#_list[@]} ))]}"
fi
if [[ -n "${FAKE_DBX_SLEEP_MS_TRUE:-}" && "${_kind}" == enter ]]; then
    _ms="${FAKE_DBX_SLEEP_MS_TRUE}"
fi
_kvar="FAKE_DBX_MS_${_kind^^}"
if [[ -n "${!_kvar:-}" ]]; then
    read -r -a _list <<<"${!_kvar}"
    _k="$(grep -c -x -F -- "$*" "${FAKE_DBX_CALLS}")"
    _ms="${_list[$(( (_k - 1) % ${#_list[@]} ))]}"
fi
# Take _ms on the FAKE clock (no real sleep: the host load never matters).
_now="$(cat "${FAKE_CLOCK_FILE}")"
printf '%s\n' "$(( _now + _ms * 1000 ))" >"${FAKE_CLOCK_FILE}"
# The host turns busy DURING the batch: the FAKE_DBX_PSI_AT-th call leaves
# a PSI of FAKE_DBX_PSI_VALUE behind (read by bench.sh after the run).
if [[ -n "${FAKE_DBX_PSI_AT:-}" ]] \
    && (( $(wc -l <"${FAKE_DBX_CALLS}") == FAKE_DBX_PSI_AT )); then
    printf 'some avg10=%s avg60=0.00 avg300=0.00 total=1\n' "${FAKE_DBX_PSI_VALUE}" >"${BENCH_PSI_FILE}"
fi
_rc="${FAKE_DBX_EXIT:-0}"
[[ "${_kind}" == shell && -n "${FAKE_DBX_EXIT_SHELL:-}" ]] && _rc="${FAKE_DBX_EXIT_SHELL}"
[[ "${_kind}" == inbox && -n "${FAKE_DBX_EXIT_INBOX:-}" ]] && _rc="${FAKE_DBX_EXIT_INBOX}"
if [[ "${_kind}" == inbox ]]; then
    printf '%s\n' "${FAKE_DBX_INBOX_OUT-$(( _ms * 1000 ))}"
fi
exit "${_rc}"
EOF
    chmod +x "${MOCKBIN}/distrobox"
}

# Print the recorded calls (empty when distrobox was never called).
_calls() {
    [[ -f "${FAKE_DBX_CALLS}" ]] && cat "${FAKE_DBX_CALLS}"
    return 0
}

# Number of recorded calls whose argv is exactly $1.
_count_calls() {
    _calls | grep -c -x -F -- "$1" || true
}

# Number of recorded inbox calls for box $1 and shell command $2: the argv
# `enter <box> -- bash -c <timer> <name> <shell>` where <timer> reads
# EPOCHREALTIME inside the box (its exact text is bench.sh's business).
_count_inbox_calls() {
    _calls | grep -c -E -- "^enter $1 -- bash -c .*EPOCHREALTIME.* $2\$" || true
}

# Print the regexp of metric $1's line: `<name>: min=<ms> median=<ms>
# max=<ms> ms`, where <ms> is an integer or a decimal number.
_metric_re() {
    local _num='[0-9]+(\.[0-9]+)?'
    printf '^%s: min=%s median=%s max=%s ms$\n' "$1" "${_num}" "${_num}" "${_num}"
}

# Regexp of the WHOLE --json object (no JSON parser in the test image, so
# validity is asserted by grammar): fixed key order, JSON strings made of
# escaped quotes / backslashes and plain printable characters only, JSON
# numbers, three metric objects. Anything a parser would choke on (a raw
# quote, a raw newline, a control character) breaks the match.
_json_object_re() {
    local _str='"([^"\\[:cntrl:]]|\\["\\])*"' _num='[0-9]+(\.[0-9]+)?'
    local _metric="\\{\"min\":${_num},\"median\":${_num},\"max\":${_num}\\}"
    printf '^\\{"box":%s,"runs":[0-9]+,"warmup":[0-9]+,"shell_cmd":%s,"unit":"ms","enter":%s,"shell":%s,"inbox":%s\\}$\n' \
        "${_str}" "${_str}" "${_metric}" "${_metric}" "${_metric}"
}

# --- self-registration -------------------------------------------------------

@test "bench executes the managed command written by setup for every metric" {
    export XDG_CONFIG_HOME="${TMP}/user-config"
    export FAKE_MANAGED_CALLS="${TMP}/managed.calls"
    # Observe the terminal's shell boundary without replacing setup or enter.
    cat >"${MOCKBIN}/sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$2" >>"${FAKE_MANAGED_CALLS}"
exec /bin/sh "$@"
EOF
    chmod +x "${MOCKBIN}/sh"
    run "${REPO_ROOT}/script/box/setup.sh" --auto-enter yes --terminal ghostty --box other
    assert_success
    local managed
    managed="$(sed -n 's/^command = //p' "${XDG_CONFIG_HOME}/ghostty/config")"
    [[ -n "${managed}" ]]
    run "${BENCH}" --box other --runs 1 --warmup 1 --shell 'fish -c exit'
    assert_success
    [[ -f "${FAKE_MANAGED_CALLS}" ]]
    run sort -u "${FAKE_MANAGED_CALLS}"
    assert_output "${managed} -- \"\$@\""
    run wc -l <"${FAKE_MANAGED_CALLS}"
    assert_output '6'
    run cat "${FAKE_DBX_CALLS}"
    assert_line 'enter other -- true'
    assert_line 'enter other -- fish -c exit'
    assert_line --regexp '^enter other -- bash -c .* bench-inbox fish -c exit$'
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "the fake distrobox is the one resolved on PATH" {
    run command -v distrobox
    assert_success
    assert_output "${MOCKBIN}/distrobox"
}

# --- argv shape and run / warmup counts --------------------------------------

@test "defaults: box dev, 2 warmup + 10 runs per metric, enter then shell (sh -c :) then inbox" {
    run "${BENCH}"
    assert_success
    # 12 identical `enter dev -- true` calls, then 12 `enter dev -- sh -c :`,
    # then 12 in-box timer calls that end with the same shell command.
    assert_equal "$(_count_calls 'enter dev -- true')" "12"
    assert_equal "$(_count_calls 'enter dev -- sh -c :')" "12"
    assert_equal "$(_count_inbox_calls dev 'sh -c :')" "12"
    assert_equal "$(_calls | wc -l)" "36"
    assert_equal "$(_calls | head -n 1)" "enter dev -- true"
    assert_equal "$(_calls | sed -n 13p)" "enter dev -- sh -c :"
    assert_equal "$(_calls | sed -n 25p | cut -d' ' -f1-5)" "enter dev -- bash -c"
    # argv boundaries: `true` is one argument (argc 4), `sh -c :` is three
    # (argc 6) - the shell command is word-split, not passed as one string;
    # the inbox argv is `enter dev -- bash -c <timer> <name> sh -c :` (argc
    # 10): the timer is ONE argument and the shell command keeps its three.
    run sort -n -u "${FAKE_DBX_CALLS}.argc"
    assert_output "4
6
10"
}

@test "the inbox timer is one bash -c argument that reads EPOCHREALTIME twice and runs the shell command as its positional arguments" {
    run "${BENCH}" --runs 1 --warmup 0
    assert_success
    local _timer
    _timer="$(_calls | sed -n '3p' | sed 's/^enter dev -- bash -c //; s/ [^ ]* sh -c :$//')"
    # Two in-box clock reads around "$@" (the shell command), a difference
    # printed as one number, the shell command's own exit status passed on.
    assert_equal "$(printf '%s' "${_timer}" | grep -o 'EPOCHREALTIME' | wc -l)" "2"
    [[ "${_timer}" == *'"$@"'* ]]
    [[ "${_timer}" == *exit* ]]
    # One line: `$*` of a call is one recorded line, so the timer has no
    # newline (the fake counts calls by whole lines).
    assert_equal "$(_calls | wc -l)" "3"
}

@test "--box / --runs / --warmup / --shell are honoured in the recorded argv and counts" {
    run "${BENCH}" --box other --runs 3 --warmup 1 --shell "fish -c exit"
    assert_success
    assert_equal "$(_count_calls 'enter other -- true')" "4"
    assert_equal "$(_count_calls 'enter other -- fish -c exit')" "4"
    assert_equal "$(_count_inbox_calls other 'fish -c exit')" "4"
    assert_equal "$(_calls | wc -l)" "12"
    refute_line --partial "dev"
}

@test "--warmup 0 records exactly --runs calls per metric" {
    run "${BENCH}" --runs 2 --warmup 0
    assert_success
    assert_equal "$(_calls | wc -l)" "6"
}

@test "--option=value forms are accepted too" {
    run "${BENCH}" --box=other --runs=2 --warmup=0 --shell="sh -c :"
    assert_success
    assert_equal "$(_count_calls 'enter other -- true')" "2"
    assert_equal "$(_count_calls 'enter other -- sh -c :')" "2"
    assert_equal "$(_count_inbox_calls other 'sh -c :')" "2"
}

# --- output shape ------------------------------------------------------------

@test "stdout is exactly the three metric lines: enter, shell, inbox" {
    local _out="${TMP}/out"
    run bash -c '"$1" --runs 2 --warmup 0 >"$2"' _ "${BENCH}" "${_out}"
    assert_success
    run cat "${_out}"
    assert_equal "${#lines[@]}" 3
    assert_line --index 0 --regexp "$(_metric_re enter)"
    assert_line --index 1 --regexp "$(_metric_re shell)"
    assert_line --index 2 --regexp "$(_metric_re inbox)"
}

# --- statistics: exact on the fake clock, warmup excluded -------------------

@test "min / median / max are the injected times, warmup excluded" {
    # Per metric: the 1 warmup call takes 300 ms, the 3 recorded runs 10 /
    # 40 / 20 ms -> sorted 10, 20, 40. The fake clock makes every sample
    # exact, and the 300 ms warmup appears nowhere.
    run env FAKE_DBX_SLEEP_MS_LIST="300 10 40 20" \
        "${BENCH}" --runs 3 --warmup 1
    assert_success
    assert_line "enter: min=10.0 median=20.0 max=40.0 ms"
    assert_line "shell: min=10.0 median=20.0 max=40.0 ms"
    assert_line "inbox: min=10.0 median=20.0 max=40.0 ms"
}

@test "host-clocked samples come from the injected BENCH_CLOCK: exact statistics, whatever the host load" {
    # Runs take 10 / 60 / 20 / 30 ms on the fake clock -> sorted 10, 20,
    # 30, 60: min 10.0, median (20 + 30) / 2 = 25.0, max 60.0, to the digit,
    # for the host-clocked enter and shell metrics as well as for inbox.
    run env FAKE_DBX_SLEEP_MS_LIST="10 60 20 30" "${BENCH}" --runs 4 --warmup 0
    assert_success
    assert_line "enter: min=10.0 median=25.0 max=60.0 ms"
    assert_line "shell: min=10.0 median=25.0 max=60.0 ms"
    assert_line "inbox: min=10.0 median=25.0 max=60.0 ms"
}

@test "an even --runs median is EXACTLY the mean of the two middle samples (inbox: injected in-box times)" {
    # The inbox numbers come from the fake's stdout, not the host clock, so
    # the statistics are deterministic: 10 / 60 / 20 / 30 ms -> min 10.0,
    # median (20 + 30) / 2 = 25.0, max 60.0, to the digit.
    run env FAKE_DBX_SLEEP_MS_LIST="10 60 20 30" "${BENCH}" --runs 4 --warmup 0
    assert_success
    assert_line "inbox: min=10.0 median=25.0 max=60.0 ms"
}

@test "the inbox metric is the in-box number, not the host round trip" {
    # Every call takes 40 ms on the host clock (so enter / shell are 40 ms),
    # but the in-box timer reports 1500 us: inbox must print 1.5 ms, i.e.
    # what the box measured, not what the host waited for.
    run env FAKE_DBX_SLEEP_MS=40 FAKE_DBX_INBOX_OUT=1500 \
        "${BENCH}" --runs 3 --warmup 0
    assert_success
    assert_line "inbox: min=1.5 median=1.5 max=1.5 ms"
    assert_line "shell: min=40.0 median=40.0 max=40.0 ms"
}

@test "--runs 1 reports min = median = max" {
    run env FAKE_DBX_SLEEP_MS=5 "${BENCH}" --runs 1 --warmup 0
    assert_success
    assert_line "enter: min=5.0 median=5.0 max=5.0 ms"
    assert_line "shell: min=5.0 median=5.0 max=5.0 ms"
    assert_line "inbox: min=5.0 median=5.0 max=5.0 ms"
}

# --- --max-ms threshold ------------------------------------------------------

@test "--max-ms above the shell median exits 0" {
    run env FAKE_DBX_SLEEP_MS=5 "${BENCH}" --runs 3 --warmup 0 --max-ms 5000
    assert_success
    assert_line --regexp "$(_metric_re shell)"
}

@test "--max-ms below the shell median exits 1, still prints all three metric lines, says why on stderr" {
    local _out="${TMP}/out" _err="${TMP}/err"
    run bash -c 'env FAKE_DBX_SLEEP_MS=30 "$1" --runs 3 --warmup 0 --max-ms 1 >"$2" 2>"$3"' \
        _ "${BENCH}" "${_out}" "${_err}"
    assert_failure 1
    run cat "${_out}"
    assert_equal "${#lines[@]}" 3
    assert_line --index 0 --regexp "$(_metric_re enter)"
    assert_line --index 1 --regexp "$(_metric_re shell)"
    assert_line --index 2 --regexp "$(_metric_re inbox)"
    run cat "${_err}"
    assert_line '[ERROR] shell median 30.0 ms exceeds --max-ms 1'
}

@test "--max-ms judges the shell metric only: a slow enter with a fast shell passes" {
    # enter (`-- true`) takes 60 ms, shell (`-- sh -c :`) 1 ms; --max-ms 20
    # sits between them, so exit 0 proves the check is on the shell median.
    run env FAKE_DBX_SLEEP_MS_TRUE=60 FAKE_DBX_SLEEP_MS=1 \
        "${BENCH}" --runs 3 --warmup 0 --max-ms 20
    assert_success
    assert_line "enter: min=60.0 median=60.0 max=60.0 ms"
    assert_line "shell: min=1.0 median=1.0 max=1.0 ms"
}

@test "--max-ms does not judge the inbox metric: a slow in-box time with a fast shell passes" {
    # The in-box timer reports 90 ms while the host round trips take 1 ms;
    # --max-ms 20 passes, so the gate ignores inbox.
    run env FAKE_DBX_SLEEP_MS=1 FAKE_DBX_INBOX_OUT=90000 \
        "${BENCH}" --runs 3 --warmup 0 --max-ms 20
    assert_success
    assert_line "inbox: min=90.0 median=90.0 max=90.0 ms"
}

# --- --max-ms matrix: below / equal / above x metric x odd / even runs -------
#
# One metric gets samples whose median sits just below, exactly at, or just
# above --max-ms 20 (odd: 3 runs, even: 4 runs, where the median is the mean
# of the two middle samples); the other two metrics take 1 ms. Only the
# shell median is judged: exit 1 above the threshold, 0 at or below it; a
# slow enter or inbox is reported exactly and never fails the run.

# Print "<samples>|<median as printed>" for parity $1 (odd|even) and
# position $2 (below|equal|above) around 20 ms.
_matrix_samples() {
    case "$1:$2" in
        odd:below)  printf '5 19 30|19.0\n' ;;
        odd:equal)  printf '5 20 30|20.0\n' ;;
        odd:above)  printf '5 21 30|21.0\n' ;;
        even:below) printf '5 19 20 30|19.5\n' ;;
        even:equal) printf '5 20 20 30|20.0\n' ;;
        even:above) printf '5 20 21 30|20.5\n' ;;
    esac
}

# Run the whole matrix for metric $1 (enter|shell|inbox) and assert every
# cell: the exact median line and the exit code. Optional $2 adds a short
# CPU load pulse to each cell, so slow hosts still exercise every cell under
# load without keeping a busy loop alive for the entire matrix.
_run_matrix() {
    local _metric="$1" _loaded="${2:-0}" _parity _pos _cell _samples _median _runs _want _rc _out
    for _parity in odd even; do
        for _pos in below equal above; do
            _cell="$(_matrix_samples "${_parity}" "${_pos}")"
            _samples="${_cell%%|*}"
            _median="${_cell#*|}"
            _runs=3
            [[ "${_parity}" == even ]] && _runs=4
            _want=0
            [[ "${_metric}" == shell && "${_pos}" == above ]] && _want=1
            rm -f "${FAKE_DBX_CALLS}"
            if (( _loaded )); then
                rm -f "${TMP}/load.ready"
                "${MOCKBIN}/cpu-load" 0.15 "${TMP}/load.ready" 3>&- &
                printf '%s\n' "$!" >"${TMP}/busy.pid"
                timeout 2 bash -c "until [[ -f \"\$1\" ]]; do :; done" _ "${TMP}/load.ready"
            fi
            _rc=0
            _out="$(env FAKE_DBX_MS_ENTER=1 FAKE_DBX_MS_SHELL=1 FAKE_DBX_MS_INBOX=1 \
                "FAKE_DBX_MS_${_metric^^}=${_samples}" \
                "${BENCH}" --runs "${_runs}" --warmup 0 --max-ms 20 2>&1)" || _rc=$?
            assert_equal "${_metric} ${_parity} ${_pos} exit ${_rc}" \
                "${_metric} ${_parity} ${_pos} exit ${_want}"
            run printf '%s\n' "${_out}"
            assert_line --regexp "^${_metric}: min=5\.0 median=${_median//./\\.} max=30\.0 ms$"
            if (( _loaded )); then
                wait "$(cat "${TMP}/busy.pid")"
                rm "${TMP}/busy.pid"
            fi
        done
    done
}

@test "matrix: the enter median below / at / above --max-ms is reported exactly and never judged (odd and even runs)" {
    _run_matrix enter
}

@test "matrix: the shell median below or at --max-ms exits 0, above it exits 1 (odd and even runs)" {
    _run_matrix shell
}

@test "matrix: the inbox median below / at / above --max-ms is reported exactly and never judged (odd and even runs)" {
    _run_matrix inbox
}

# The load fixture must stop itself even if the matrix fails or is interrupted.
@test "artificial CPU load is ready even when timeout kills bash before its command starts" {
    # Non-interactive bash sources BASH_ENV before executing its command.
    # Stall only the bounded child, so timeout kills it before it can write ready.
    cat >"${TMP}/stall-child.bash" <<'EOF'
if [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then
    while :; do :; done
fi
EOF
    run env BASH_ENV="${TMP}/stall-child.bash" \
        timeout 3 "${MOCKBIN}/cpu-load" 0.15 "${TMP}/load.ready"
    assert_success
    run cat "${TMP}/load.ready"
    assert_success
    assert_output "ready"
    _run_matrix enter 1
    _run_matrix shell 1
    _run_matrix inbox 1
}

@test "artificial CPU load stops on its own within a short deadline" {
    run timeout 3 "${MOCKBIN}/cpu-load" 1 "${TMP}/load.ready"
    assert_success
    run cat "${TMP}/load.ready"
    assert_output "ready"
}

# Load guard (issue #249): rerun all cells with one CPU busy loop per cell,
# capped at 0.15 seconds each (2.7 seconds total), inside this container.
@test "matrix under an artificial CPU load: every cell is unchanged" {
    _run_matrix enter 1
    _run_matrix shell 1
    _run_matrix inbox 1
}

# End the wrapper on failure too. Its independent timeout process still
# stops the busy worker within its short deadline if the wrapper ends early.
teardown() {
    local _pid
    if [[ -f "${TMP}/busy.pid" ]]; then
        _pid="$(cat "${TMP}/busy.pid")"
        if kill -0 "${_pid}" 2>/dev/null; then
            kill "${_pid}" 2>/dev/null || return 0
        fi
    fi
}

# --- --json ------------------------------------------------------------------

@test "--json prints exactly one JSON object with box, runs, warmup, shell_cmd and all three metrics" {
    local _out="${TMP}/out"
    run bash -c 'env FAKE_DBX_SLEEP_MS=2 "$1" --runs 3 --warmup 1 --json >"$2"' \
        _ "${BENCH}" "${_out}"
    assert_success
    run cat "${_out}"
    assert_equal "${#lines[@]}" 1
    assert_output --regexp "$(_json_object_re)"
    assert_output --partial '"enter":{"min":2.0,"median":2.0,"max":2.0}'
    assert_output --partial '"shell":{"min":2.0,"median":2.0,"max":2.0}'
    assert_output --partial '"box":"dev"'
    assert_output --partial '"runs":3'
    assert_output --partial '"warmup":1'
    assert_output --partial '"shell_cmd":"sh -c :"'
    assert_output --partial '"unit":"ms"'
    assert_output --regexp '"enter":\{"min":[0-9.]+,"median":[0-9.]+,"max":[0-9.]+\}'
    assert_output --regexp '"shell":\{"min":[0-9.]+,"median":[0-9.]+,"max":[0-9.]+\}'
    assert_output --regexp '"inbox":\{"min":2(\.0)?,"median":2(\.0)?,"max":2(\.0)?\}'
    # No plain-text metric line alongside the object.
    refute_output --regexp '^(enter|shell|inbox): min='
}

@test "--json escapes a double quote and a backslash in shell_cmd and stays valid JSON" {
    run "${BENCH}" --runs 1 --warmup 0 --json --shell 'sh -c "\:"'
    assert_success
    assert_output --partial '"shell_cmd":"sh -c \"\\:\""'
    # stderr (the [INFO] lines) is merged into $output by `run`; the object
    # is the one stdout line, so the whole-object grammar is checked per line.
    assert_line --regexp "$(_json_object_re)"
}

@test "--json with a failing --max-ms still exits 1 after printing the object" {
    run env FAKE_DBX_SLEEP_MS=30 "${BENCH}" --runs 1 --warmup 0 --json --max-ms 1
    assert_failure 1
    assert_line --regexp '^\{.*"shell":\{.*"inbox":\{.*\}$'
}

# --- input validation: --box / --shell that would break --json ---------------

@test "a --box outside [A-Za-z0-9._-]+ is refused with exit 2, nothing on stdout, nothing recorded" {
    local _bad _out="${TMP}/out" _err="${TMP}/err"
    for _bad in 'a"b' 'a b' $'a\nb' 'a\b' 'a/b' "a\$b" "a'b"; do
        run bash -c '"$1" --json --box "$2" >"$3" 2>"$4"' _ "${BENCH}" "${_bad}" "${_out}" "${_err}"
        assert_failure 2
        run cat "${_out}"
        assert_output ""
        run cat "${_err}"
        assert_output --regexp '^bench\.sh: invalid --box .*\(see --help\)$'
        assert_equal "$(_calls)" ""
    done
}

@test "a --box of letters, digits, dot, underscore and dash is accepted" {
    run "${BENCH}" --runs 1 --warmup 0 --json --box 'My_box.v2-x'
    assert_success
    assert_output --partial '"box":"My_box.v2-x"'
    assert_equal "$(_count_calls 'enter My_box.v2-x -- true')" "1"
}

@test "a --shell containing a control character (newline, tab, escape) is refused with exit 2, nothing recorded" {
    local _bad _out="${TMP}/out" _err="${TMP}/err"
    for _bad in $'sh -c :\n' $'sh\t-c :' $'sh -c :\x1b' $'\x01sh -c :'; do
        run bash -c '"$1" --json --shell "$2" >"$3" 2>"$4"' _ "${BENCH}" "${_bad}" "${_out}" "${_err}"
        assert_failure 2
        run cat "${_out}"
        assert_output ""
        run cat "${_err}"
        assert_equal "${#lines[@]}" 1
        assert_output --regexp '^bench\.sh: invalid --shell .*\(see --help\)$'
        assert_equal "$(_calls)" ""
    done
}

@test "an invalid --box is refused before the metrics run even when it comes last" {
    run "${BENCH}" --runs 3 --warmup 0 --box 'a"b'
    assert_failure 2
    assert_output --regexp '^bench\.sh: invalid --box .*\(see --help\)$'
    assert_equal "$(_calls)" ""
}

# --- the tool owns its CLI: --help and unknown / invalid options --------------

@test "--help exits 0, names every option and the three metrics, and calls distrobox nothing" {
    run "${BENCH}" --help
    assert_success
    assert_output --partial "Usage: bench.sh"
    local _opt
    for _opt in --box --runs --warmup --max-ms --json --shell --help; do
        assert_output --partial "${_opt}"
    done
    assert_line --regexp '^ *enter '
    assert_line --regexp '^ *shell '
    assert_line --regexp '^ *inbox '
    refute_output --regexp '^(enter|shell|inbox): min='
    assert_equal "$(_calls)" ""
}

@test "-h is the same as --help" {
    run "${BENCH}" --help
    local _long="${output}"
    run "${BENCH}" -h
    assert_success
    assert_output "${_long}"
}

@test "an unknown option exits 2 with the documented message on stderr, nothing on stdout, nothing recorded" {
    local _out="${TMP}/out" _err="${TMP}/err"
    run bash -c '"$1" --bogus >"$2" 2>"$3"' _ "${BENCH}" "${_out}" "${_err}"
    assert_failure 2
    run cat "${_out}"
    assert_output ""
    run cat "${_err}"
    assert_output "bench.sh: unknown option '--bogus' (see --help)"
    assert_equal "$(_calls)" ""
}

@test "an unknown option is refused even when combined with --help: exit 2 and no usage" {
    run "${BENCH}" --help --bogus
    assert_failure 2
    assert_output "bench.sh: unknown option '--bogus' (see --help)"
    refute_output --partial "Usage:"
    assert_equal "$(_calls)" ""
}

@test "an unknown option after valid ones is refused before anything runs" {
    run "${BENCH}" --runs 3 --box dev --bogus
    assert_failure 2
    assert_output "bench.sh: unknown option '--bogus' (see --help)"
    assert_equal "$(_calls)" ""
}

@test "--runs 0, --runs abc, --warmup -1, --max-ms 0 and --max-ms 1.5 are refused with exit 2, nothing recorded" {
    local _bad _argv
    for _bad in "--runs 0" "--runs abc" "--warmup -1" "--max-ms 0" "--max-ms 1.5"; do
        read -r -a _argv <<<"${_bad}"
        run "${BENCH}" "${_argv[@]}"
        assert_failure 2
        assert_output --regexp "^bench\.sh: ${_argv[0]} .*\(see --help\)$"
        assert_equal "$(_calls)" ""
    done
}

@test "an option missing its value is refused with exit 2" {
    local _opt
    for _opt in --box --runs --warmup --max-ms --shell; do
        run "${BENCH}" "${_opt}"
        assert_failure 2
        assert_output "bench.sh: ${_opt} requires an argument (see --help)"
    done
    assert_equal "$(_calls)" ""
}

@test "an empty --box or --shell is refused with exit 2" {
    run "${BENCH}" --box ""
    assert_failure 2
    assert_output --partial "bench.sh: --box"
    run "${BENCH}" --shell ""
    assert_failure 2
    assert_output --partial "bench.sh: --shell"
    assert_equal "$(_calls)" ""
}

# --- failures of the measured command ----------------------------------------

@test "a distrobox enter that exits non-zero aborts the measurement: exit 1, no metric line" {
    run env FAKE_DBX_EXIT=3 "${BENCH}" --runs 2 --warmup 0
    assert_failure 1
    assert_output --partial "[ERROR] enter:"
    assert_output --partial "exited 3"
    refute_output --regexp '^(enter|shell|inbox): min='
    # It stopped at the first failing run: exactly one call was made.
    assert_equal "$(_calls | wc -l)" "1"
}

@test "a shell run that fails after every enter run passed aborts at the shell metric: exit 1, no metric line" {
    run env FAKE_DBX_EXIT_SHELL=4 "${BENCH}" --runs 2 --warmup 1
    assert_failure 1
    assert_output --partial "[ERROR] shell:"
    assert_output --partial "exited 4"
    refute_output --partial "[ERROR] enter:"
    refute_output --regexp '^(enter|shell|inbox): min='
    # 3 enter calls passed, the first shell call failed, inbox never ran.
    assert_equal "$(_count_calls 'enter dev -- true')" "3"
    assert_equal "$(_count_calls 'enter dev -- sh -c :')" "1"
    assert_equal "$(_calls | wc -l)" "4"
}

@test "an inbox run that fails after enter and shell passed aborts at the inbox metric: exit 1, no metric line" {
    run env FAKE_DBX_EXIT_INBOX=5 "${BENCH}" --runs 2 --warmup 1
    assert_failure 1
    assert_output --partial "[ERROR] inbox:"
    assert_output --partial "exited 5"
    refute_output --regexp '^(enter|shell|inbox): min='
    assert_equal "$(_count_inbox_calls dev 'sh -c :')" "1"
    assert_equal "$(_calls | wc -l)" "7"
}

@test "an in-box timer that prints something other than an integer aborts the measurement: exit 1, no metric line" {
    run env FAKE_DBX_INBOX_OUT="bash: EPOCHREALTIME: unbound" "${BENCH}" --runs 2 --warmup 0
    assert_failure 1
    assert_output --partial "[ERROR] inbox:"
    refute_output --regexp '^(enter|shell|inbox): min='
    assert_equal "$(_count_inbox_calls dev 'sh -c :')" "1"
}

# A test-only clock (BENCH_CLOCK) that prints $1 and exits $2.
_bad_clock() {
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\nexit %d\n' "$1" "$2" >"${MOCKBIN}/bad-clock"
    chmod +x "${MOCKBIN}/bad-clock"
}

@test "a BENCH_CLOCK that prints something other than an integer aborts the measurement: exit 1, no metric line" {
    _bad_clock "soon" 0
    run env BENCH_CLOCK="${MOCKBIN}/bad-clock" "${BENCH}" --runs 2 --warmup 0
    assert_failure 1
    assert_line --regexp "^\[ERROR\] enter: BENCH_CLOCK .*bad-clock' printed 'soon' instead of an integer on run 1 - measurement aborted$"
    refute_output --regexp '^(enter|shell|inbox): min='
}

@test "a BENCH_CLOCK that exits non-zero aborts the measurement: exit 1, no metric line" {
    _bad_clock "1700000000000000" 4
    run env BENCH_CLOCK="${MOCKBIN}/bad-clock" "${BENCH}" --runs 2 --warmup 0
    assert_failure 1
    assert_line --regexp "^\[ERROR\] enter: BENCH_CLOCK .*bad-clock' exited 4 on run 1 - measurement aborted$"
    refute_output --regexp '^(enter|shell|inbox): min='
}

@test "without BENCH_CLOCK the host clock is the real one (EPOCHREALTIME): the production path still measures" {
    run env -u BENCH_CLOCK "${BENCH}" --runs 2 --warmup 0
    assert_success
    assert_line --regexp "$(_metric_re enter)"
    assert_line --regexp "$(_metric_re shell)"
    # The fake clock was never read, so it cannot have produced the numbers.
    assert_line "inbox: min=0.0 median=0.0 max=0.0 ms"
}

@test "distrobox missing from PATH exits 127 before measuring" {
    # A PATH with only what the tool itself needs (dirname for its own
    # path, sort for the statistics) and no distrobox. bash is resolved to
    # an absolute path BEFORE the PATH is replaced (env would otherwise
    # look `bash` up in the emptied PATH).
    local _only="${TMP}/only" _bash _tool
    _bash="$(command -v bash)"
    mkdir -p "${_only}"
    for _tool in dirname sort; do
        ln -s "$(command -v "${_tool}")" "${_only}/${_tool}"
    done
    run -127 env PATH="${_only}" "${_bash}" "${BENCH}" --runs 1 --warmup 0
    assert_output --partial "[ERROR] distrobox not found on PATH"
    assert_equal "$(_calls)" ""
}

# --- quiet-host precondition and the inconclusive verdict (issue #181) ------

# The ERROR line of a host that never got quiet: PSI path, last avg10, the
# seconds waited, loadavg (recorded only), and what to do.
_busy_re() {
    printf '^\\[ERROR\\] host too busy to measure \\(inconclusive\\): %s some avg10=%s for %ss; loadavg=[^;]+; re-run when idle$\n' \
        "${BENCH_PSI_FILE//./\\.}" "${1//./\\.}" "$2"
}

@test "a quiet host is measured after 5 quiet seconds: exit 0, the PSI path, value and loadavg on stderr" {
    local _out="${TMP}/out" _err="${TMP}/err"
    run bash -c '"$1" --runs 2 --warmup 0 >"$2" 2>"$3"' _ "${BENCH}" "${_out}" "${_err}"
    assert_success
    # Readings at t = 0..5 s: five one-second polls, no more.
    assert_equal "$(_sleeps)" "5"
    run sort -u "${FAKE_SLEEP_CALLS}"
    assert_output "1"
    assert_equal "$(_calls | wc -l)" "6"
    run cat "${_out}"
    assert_equal "${#lines[@]}" 3
    run cat "${_err}"
    assert_line --regexp "^\[INFO\] host quiet: ${BENCH_PSI_FILE//./\\.} some avg10=0\.00 <= 2\.00 for 5s; loadavg=.+$"
    assert_line --regexp "^\[INFO\] host stayed quiet: ${BENCH_PSI_FILE//./\\.} some avg10 peak=0\.00 over every run; loadavg=.+$"
}

@test "some avg10 of exactly 2.00 counts as quiet (the limit is inclusive)" {
    _psi 2.00
    run "${BENCH}" --runs 1 --warmup 0
    assert_success
    assert_equal "$(_sleeps)" "5"
}

@test "a host busy until --max-wait runs out is inconclusive: exit 3, no distrobox call, nothing on stdout" {
    _psi 9.50
    local _out="${TMP}/out" _err="${TMP}/err"
    run bash -c '"$1" --max-wait 7 --max-ms 300 >"$2" 2>"$3"' _ "${BENCH}" "${_out}" "${_err}"
    assert_failure 3
    assert_equal "$(_sleeps)" "7"
    assert_equal "$(_calls)" ""
    run cat "${_out}"
    assert_output ""
    run cat "${_err}"
    assert_line --regexp "$(_busy_re 9.50 7)"
    refute_line --partial "within --max-ms"
    refute_line --partial "exceeds --max-ms"
}

@test "quiet seconds must be CONSECUTIVE: a spike restarts the 5-second count" {
    # t=0..2 quiet, t=3 busy, quiet from t=4: done at t=9 (9 polls).
    FAKE_PSI_SEQ="0.00 0.00 5.00 0.00" run "${BENCH}" --runs 1 --warmup 0 --max-wait 20
    assert_success
    assert_equal "$(_sleeps)" "9"
}

@test "fewer than 5 quiet seconds before --max-wait is still inconclusive (exit 3)" {
    run "${BENCH}" --runs 1 --warmup 0 --max-wait 3
    assert_failure 3
    assert_line --regexp "$(_busy_re 0.00 3)"
    assert_equal "$(_calls)" ""
}

@test "a host that turns quiet after a few seconds is then measured: exit 0" {
    _psi 9.00
    # t=0..2 busy, quiet from t=3 on: 5 quiet seconds end at t=8.
    FAKE_PSI_SEQ="9.00 9.00 1.50" run "${BENCH}" --runs 2 --warmup 0 --max-wait 10
    assert_success
    assert_equal "$(_sleeps)" "8"
    assert_line --regexp "$(_metric_re shell)"
    assert_line --regexp '^\[INFO\] host quiet: .* some avg10=1\.50 <= 2\.00 for 5s; loadavg=.+$'
}

@test "--max-wait defaults to 60 s, or 120 s when CI is set" {
    _psi 50.00
    run env -u CI "${BENCH}"
    assert_failure 3
    assert_equal "$(_sleeps)" "60"
    rm -f "${FAKE_SLEEP_CALLS}"
    CI=true run "${BENCH}"
    assert_failure 3
    assert_equal "$(_sleeps)" "120"
    assert_equal "$(_calls)" ""
}

@test "a PSI spike mid-run voids the whole batch: exit 3, no metric line, measuring stops there" {
    local _out="${TMP}/out" _err="${TMP}/err"
    run bash -c 'FAKE_DBX_PSI_AT=2 FAKE_DBX_PSI_VALUE=7.25 "$1" --runs 3 --warmup 0 --max-ms 5000 >"$2" 2>"$3"' \
        _ "${BENCH}" "${_out}" "${_err}"
    assert_failure 3
    # The 2nd run left the host busy: its after-run reading voids the batch.
    assert_equal "$(_calls | wc -l)" "2"
    run cat "${_out}"
    assert_output ""
    run cat "${_err}"
    assert_line --regexp "^\[ERROR\] host too busy mid-run \(inconclusive\): ${BENCH_PSI_FILE//./\\.} some avg10=7\.25 after enter run 2; loadavg=[^;]+; batch void, re-run when idle$"
    refute_line --partial "max-ms"
}

@test "a PSI spike mid-run voids the batch even when --json and every sample so far were fast" {
    run env FAKE_DBX_PSI_AT=5 FAKE_DBX_PSI_VALUE=3.00 "${BENCH}" --runs 2 --warmup 0 --json
    assert_failure 3
    refute_line --regexp '^\{'
    assert_line --regexp 'after inbox run 1; loadavg='
}

# Codex round 1 on PR #236: a run that FAILS must still get its after-run
# PSI check. A failure on a host that turned busy during that very run is
# not evidence of a broken box, so the verdict is 3 (inconclusive), not 1.
@test "a failing run on a host that turned busy during it is inconclusive (exit 3), not a failure (exit 1)" {
    run env FAKE_DBX_EXIT=4 FAKE_DBX_PSI_AT=1 FAKE_DBX_PSI_VALUE=7.25 \
        "${BENCH}" --runs 2 --warmup 0
    assert_failure 3
    assert_line --regexp "^\[ERROR\] host too busy mid-run \(inconclusive\): ${BENCH_PSI_FILE//./\\.} some avg10=7\.25 after enter run 1; loadavg=[^;]+; batch void, re-run when idle$"
    refute_line --partial "measurement aborted"
    refute_output --regexp '^(enter|shell|inbox): min='
    assert_equal "$(_calls | wc -l)" "1"
}

@test "a failing run on a host that stayed quiet is still a failure (exit 1)" {
    run env FAKE_DBX_EXIT_SHELL=4 "${BENCH}" --runs 1 --warmup 0
    assert_failure 1
    assert_line --partial "exited 4 on run 1 - measurement aborted"
    refute_line --partial "inconclusive"
}

# Issue #181 決定: PSI is RECORDED before and after every sample - one
# stderr line per sample boundary (path and value), stdout unchanged.
@test "every run records its PSI before and after it on stderr (path and value), stdout unchanged" {
    local _out="${TMP}/out" _err="${TMP}/err" _m _k _p
    run bash -c '"$1" --runs 2 --warmup 1 >"$2" 2>"$3"' _ "${BENCH}" "${_out}" "${_err}"
    assert_success
    run cat "${_out}"
    assert_equal "${#lines[@]}" 3
    run grep -c '^\[INFO\] psi ' "${_err}"
    assert_output "18"
    run cat "${_err}"
    _p="${BENCH_PSI_FILE//./\\.}"
    for _m in enter shell inbox; do
        for _k in 1 2 3; do
            assert_line --regexp "^\[INFO\] psi before ${_m} run ${_k}: ${_p} some avg10=0\.00$"
            assert_line --regexp "^\[INFO\] psi after ${_m} run ${_k}: ${_p} some avg10=0\.00$"
        done
    done
}

@test "the per-run PSI records come in run order: before run k, then after run k" {
    run "${BENCH}" --runs 1 --warmup 1
    assert_success
    run bash -c 'grep -E "^\[INFO\] psi " <<<"$1" | sed -E "s/: .*//"' _ "${output}"
    assert_output "$(printf '[INFO] psi %s\n' \
        'before enter run 1' 'after enter run 1' 'before enter run 2' 'after enter run 2' \
        'before shell run 1' 'after shell run 1' 'before shell run 2' 'after shell run 2' \
        'before inbox run 1' 'after inbox run 1' 'before inbox run 2' 'after inbox run 2')"
}

# Codex round 1 on PR #236: `some avg10 <= 2.00` is exact at any number of
# decimals - nothing is truncated to two places.
@test "the 2.00 limit is exact at any precision: 2.00 and 1.999 are quiet, 2.001 and 2.01 are busy" {
    local _v
    for _v in 2.00 1.999 2.000 0.5 2; do
        _psi "${_v}"
        rm -f "${FAKE_SLEEP_CALLS}"
        run "${BENCH}" --runs 1 --warmup 0 --max-wait 6
        assert_success
        assert_equal "$(_sleeps)" "5"
    done
    for _v in 2.001 2.01 2.0000001 10.00 3; do
        _psi "${_v}"
        rm -f "${FAKE_SLEEP_CALLS}" "${FAKE_DBX_CALLS}"
        run "${BENCH}" --runs 1 --warmup 0 --max-wait 6
        assert_failure 3
        assert_line --regexp "$(_busy_re "${_v}" 6)"
        assert_equal "$(_calls)" ""
    done
}

@test "a mid-run reading just above the limit (2.001) voids the batch" {
    run env FAKE_DBX_PSI_AT=1 FAKE_DBX_PSI_VALUE=2.001 "${BENCH}" --runs 1 --warmup 0
    assert_failure 3
    assert_line --regexp 'some avg10=2\.001 after enter run 1; loadavg='
}

@test "the stayed-quiet peak compares exactly (1.999 beats 1.99)" {
    FAKE_PSI_SEQ="1.99" run env FAKE_DBX_PSI_AT=2 FAKE_DBX_PSI_VALUE=1.999 \
        "${BENCH}" --runs 1 --warmup 0
    assert_success
    assert_line --regexp '^\[INFO\] host stayed quiet: .* some avg10 peak=1\.999 over every run; loadavg=.+$'
}

# A reading that fails after an earlier good one must not report the stale
# value: the error shows `?` for "no reading".
@test "an unreadable PSI mid-run is reported as avg10=? (never the last good value)" {
    run env FAKE_DBX_PSI_AT=1 FAKE_DBX_PSI_VALUE=garbage "${BENCH}" --runs 1 --warmup 0
    assert_failure 3
    assert_line --regexp "^\[ERROR\] host too busy mid-run \(inconclusive\): ${BENCH_PSI_FILE//./\\.} some avg10=\? after enter run 1; loadavg=[^;]+; batch void, re-run when idle$"
}

@test "no readable PSI: a warning says so and the measurement runs unguarded (exit 0, no wait)" {
    local _out="${TMP}/out" _err="${TMP}/err"
    run bash -c 'BENCH_PSI_FILE="$4" "$1" --runs 2 --warmup 0 >"$2" 2>"$3"' \
        _ "${BENCH}" "${_out}" "${_err}" "${TMP}/absent"
    assert_success
    assert_equal "$(_sleeps)" "0"
    run cat "${_out}"
    assert_equal "${#lines[@]}" 3
    run cat "${_err}"
    assert_line --regexp '^\[WARN\] no CPU pressure \(PSI\) readable .* - quiet-host check skipped, measuring anyway; loadavg=.+$'
}

@test "a PSI file without a parsable some avg10 counts as no PSI (warned, measured)" {
    printf 'garbage\n' >"${BENCH_PSI_FILE}"
    run "${BENCH}" --runs 1 --warmup 0
    assert_success
    assert_line --regexp '^\[WARN\] no CPU pressure \(PSI\) readable'
    assert_equal "$(_sleeps)" "0"
}

# Print the PSI path bench.sh picks (sourced, no BENCH_PSI_FILE) with the
# cgroup v2 mount $1, the /proc/self/cgroup stand-in $2 and the
# /proc/pressure/cpu stand-in $3.
_resolved_psi() {
    bash -c 'unset BENCH_PSI_FILE; source "$1"; CGROUP_FS="$2"; PROC_SELF_CGROUP="$3"; PROC_PSI="$4"; _psi_resolve; printf "%s\n" "${PSI_PATH}"' \
        _ "${BENCH}" "$@"
}

@test "PSI source: the process's own cgroup v2 cpu.pressure first, /proc/pressure/cpu as fallback, none when neither reads" {
    local _cg="${TMP}/cgfs" _proc="${TMP}/proc.cpu" _self="${TMP}/self.cgroup"
    mkdir -p "${_cg}/user.slice/x.scope"
    printf '0::/user.slice/x.scope\n' >"${_self}"
    _psi 0.10 "${_cg}/user.slice/x.scope/cpu.pressure"
    _psi 0.20 "${_proc}"
    run _resolved_psi "${_cg}" "${_self}" "${_proc}"
    assert_success
    assert_output "${_cg}/user.slice/x.scope/cpu.pressure"
    rm "${_cg}/user.slice/x.scope/cpu.pressure"
    run _resolved_psi "${_cg}" "${_self}" "${_proc}"
    assert_output "${_proc}"
    rm "${_proc}"
    run _resolved_psi "${_cg}" "${_self}" "${_proc}"
    assert_success
    assert_output ""
}

@test "--max-wait 0, abc, -1 and 1.5 are refused with exit 2; a missing value too; nothing recorded, no wait" {
    local _bad
    for _bad in 0 abc -1 1.5; do
        run "${BENCH}" --max-wait "${_bad}"
        assert_failure 2
        assert_output --regexp "^bench\.sh: --max-wait requires an integer >= 1, got '${_bad//./\\.}' \(see --help\)$"
    done
    run "${BENCH}" --max-wait
    assert_failure 2
    assert_output "bench.sh: --max-wait requires an argument (see --help)"
    assert_equal "$(_calls)" ""
    assert_equal "$(_sleeps)" "0"
}

@test "--max-wait=N is accepted like the other options" {
    _psi 9.00
    run "${BENCH}" --max-wait=2
    assert_failure 3
    assert_equal "$(_sleeps)" "2"
}

@test "--help documents --max-wait, the quiet-host rule, exit 3 and the test-only BENCH_PSI_FILE" {
    run "${BENCH}" --help
    assert_success
    assert_output --partial "--max-wait N"
    assert_output --partial "some avg10 <= 2.00"
    assert_output --partial "/proc/pressure/cpu"
    assert_output --regexp "3 +inconclusive"
    assert_output --partial "BENCH_PSI_FILE"
    assert_output --partial "tests only"
    assert_equal "$(_sleeps)" "0"
}

@test "--help documents the test-only BENCH_CLOCK and says the real clock is EPOCHREALTIME" {
    run "${BENCH}" --help
    assert_success
    assert_output --partial "BENCH_CLOCK"
    assert_output --regexp "BENCH_CLOCK +run this program for the host clock"
    assert_output --partial "tests only"
    assert_output --partial "EPOCHREALTIME"
}

# --- doc/manifest.md states the system-real evidence contract ---------------

# Print the "(d) 進盒延遲 gate" paragraph of doc/manifest.md 測試對應 (from
# its "(d)" marker up to the "(e)" marker), unwrapped into one line so a
# phrase the doc wraps across lines can still be matched as one string.
_manifest_gate_paragraph() {
    sed -n '/(d) 進盒延遲/,/(e) 冪等/p' "${REPO_ROOT}/doc/manifest.md" \
        | sed 's/^[[:space:]]*//' | tr '\n' ' '
}

# The system-real gate (test/system/real_engine_spec.bats) asserts all
# THREE metric lines and pins `fish -c exit` in BOTH the `[INFO] shell:`
# and the `[INFO] inbox:` line (_assert_fish_timed), in the positive and
# the negative case alike. Codex round 2 on PR #169: a reader judges the
# system-real evidence against this paragraph, so it must state the same
# contract the spec enforces - a paragraph that still says "two metric
# lines" and only names the shell INFO line describes the pre-#162 spec.
@test "doc/manifest.md 測試對應 (d) states the system-real evidence contract: three metric lines, fish pinned in the shell AND inbox INFO lines, in both cases" {
    run _manifest_gate_paragraph
    assert_success
    assert_output --partial "\`enter: ...\` / \`shell: ...\` / \`inbox: ...\` 三行指標存在"
    assert_output --partial "\`[INFO] shell: ... of '<受管 command> -- fish -c exit' done\`"
    assert_output --partial "\`[INFO] inbox: ... of '<受管 command> -- bash -c <timer> bench-inbox fish -c exit' done\`"
    assert_output --partial "三行指標仍在"
    assert_output --partial "\`sh -c :\`"
    refute_output --partial "兩行指標"
    refute_output --partial "兩行 指標"
}

# --- errexit (issue #195) ----------------------------------------------------

@test "bench.sh runs under set -euo pipefail (one set line, errexit included)" {
    run grep -E '^set -[a-z]+( pipefail)?$' "${BENCH}"
    assert_success
    assert_output 'set -euo pipefail'
}

# A run that exits non-zero must be REPORTED by _run_metric (the documented
# `exited <rc> on run <n> - measurement aborted` line, return 1), not kill
# the shell at the runner under errexit with the command's own status.
@test "a failing host-clocked run is reported and returns 1 with errexit on in the caller" {
    run bash -c 'set -euo pipefail; source "$1"; OPT_WARMUP=0; OPT_RUNS=1; s=(); _run_metric enter s _time_cmd bash -c "exit 3"' \
        _ "${BENCH}"
    assert_failure 1
    assert_output --partial "enter: 'bash -c exit 3' exited 3 on run 1 - measurement aborted"
}

@test "a failing in-box run is reported and returns 1 with errexit on in the caller" {
    run bash -c 'set -euo pipefail; source "$1"; OPT_WARMUP=0; OPT_RUNS=1; s=(); _run_metric inbox s _inbox_cmd bash -c "exit 4"' \
        _ "${BENCH}"
    assert_failure 1
    assert_output --partial "inbox: 'bash -c exit 4' exited 4 on run 1 - measurement aborted"
}

@test "box PSI: busy box with quiet bench is inconclusive instead of a latency verdict" {
    local _box="${TMP}/box.cpu.pressure"
    _psi 7.25 "${_box}"
    run env BENCH_BOX_PSI_FILE="${_box}" FAKE_DBX_SLEEP_MS=400 \
        "${BENCH}" --runs 1 --warmup 0 --max-ms 300 --max-wait 5
    assert_failure 3
    assert_output --partial "${_box} some avg10=7.25"
    assert_equal "$(_calls)" ""
    assert_equal "$(_sleeps)" "5"
}
