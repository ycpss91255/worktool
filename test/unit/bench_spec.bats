#!/usr/bin/env bats
# test/unit/bench_spec.bats - script/box/bench.sh enter-latency measurement
# and CLI (M3, issue #150)
#
# Written test-first (RED) before the tool exists, then bench.sh is
# implemented to pass (GREEN).
#
# Contract under test:
#   - Two metrics, each timed with bash EPOCHREALTIME (no hyperfine):
#       enter = `distrobox enter <box> -- true`
#       shell = `distrobox enter <box> -- <shell>`   (default `sh -c :`)
#     Every metric runs --warmup unrecorded times, then --runs recorded
#     times (defaults: box dev, runs 10, warmup 2), the enter metric first.
#   - Plain text on stdout, one line per metric, nothing else:
#       enter: min=<ms> median=<ms> max=<ms> ms
#       shell: min=<ms> median=<ms> max=<ms> ms
#     with min <= median <= max and the warmup runs excluded from the
#     statistics. --json replaces the two lines with ONE JSON object.
#   - --max-ms N: exit 1 when the SHELL median exceeds N ms (the numbers
#     are still printed; the reason goes to stderr), exit 0 otherwise.
#   - The tool owns its CLI: `--help` / `-h` print usage and exit 0 after
#     the WHOLE command line was parsed; an unknown option is refused with
#     `bench.sh: unknown option '<x>' (see --help)` on stderr, exit 2,
#     nothing on stdout, and distrobox is never called; a bad --runs /
#     --warmup / --max-ms value is refused the same way (exit 2).
#   - A distrobox run that exits non-zero aborts the measurement (exit 1,
#     no statistics line); a missing distrobox is exit 127.
#
# HOW
#   A FAKE `distrobox` sits first on PATH. It records every call (one line
#   `$*` per call, and `$#` per call in a sibling file) and sleeps a
#   configurable number of milliseconds: FAKE_DBX_SLEEP_MS for every call;
#   FAKE_DBX_SLEEP_MS_LIST instead gives the k-th call with an identical
#   argv the k-th entry (cycling), so one metric's warmup can be slow and
#   its runs fast, which makes the "warmup excluded" claim checkable;
#   FAKE_DBX_SLEEP_MS_TRUE overrides the sleep for the `-- true` argv only
#   (the enter metric), so the two metrics can differ. FAKE_DBX_EXIT injects
#   a failing enter. `sleep` never returns early, so a run's measured time
#   is a hard LOWER bound on the requested sleep; upper bounds are only
#   asserted with a wide margin (the runner may be loaded).

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    BENCH="${REPO_ROOT}/script/box/bench.sh"
    TMP="${BATS_TEST_TMPDIR}"
    MOCKBIN="${TMP}/bin"
    export FAKE_DBX_CALLS="${TMP}/distrobox.calls"
    _install_fake_distrobox
    PATH="${MOCKBIN}:${PATH}"
}

# The fake distrobox described in the header.
_install_fake_distrobox() {
    mkdir -p "${MOCKBIN}"
    cat >"${MOCKBIN}/distrobox" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$#" >>"${FAKE_DBX_CALLS}.argc"
printf '%s\n' "$*" >>"${FAKE_DBX_CALLS}"
_ms="${FAKE_DBX_SLEEP_MS:-0}"
if [[ -n "${FAKE_DBX_SLEEP_MS_LIST:-}" ]]; then
    read -r -a _list <<<"${FAKE_DBX_SLEEP_MS_LIST}"
    _k="$(grep -c -x -F -- "$*" "${FAKE_DBX_CALLS}")"
    _ms="${_list[$(( (_k - 1) % ${#_list[@]} ))]}"
fi
if [[ -n "${FAKE_DBX_SLEEP_MS_TRUE:-}" && "$*" == *" -- true" ]]; then
    _ms="${FAKE_DBX_SLEEP_MS_TRUE}"
fi
if (( _ms > 0 )); then
    printf -v _s '%d.%03d' $(( _ms / 1000 )) $(( _ms % 1000 ))
    sleep "${_s}"
fi
exit "${FAKE_DBX_EXIT:-0}"
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

# Print the regexp of metric $1's line: `<name>: min=<ms> median=<ms>
# max=<ms> ms`, where <ms> is an integer or a decimal number.
_metric_re() {
    local _num='[0-9]+(\.[0-9]+)?'
    printf '^%s: min=%s median=%s max=%s ms$\n' "$1" "${_num}" "${_num}" "${_num}"
}

# Print the min / median / max of metric $1 from $lines, in TENTHS of a
# millisecond as integers (bash has no float comparison): `12.3` -> 123,
# `12` -> 120.
_metric_tenths() {
    local _line _v _out=""
    _line="$(printf '%s\n' "${lines[@]}" | grep -E "^$1: ")"
    [[ -n "${_line}" ]] || return 1
    for _v in "${_line#*min=}" "${_line#*median=}" "${_line#*max=}"; do
        _v="${_v%% *}"
        if [[ "${_v}" == *.* ]]; then
            _v="${_v%.*}$(printf '%s' "${_v#*.}" | cut -c1)"
        else
            _v="${_v}0"
        fi
        _out+="$(( 10#${_v} )) "
    done
    printf '%s\n' "${_out% }"
}

# --- self-registration -------------------------------------------------------

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

@test "defaults: box dev, 2 warmup + 10 runs per metric, enter then shell (sh -c :)" {
    run "${BENCH}"
    assert_success
    # 12 identical `enter dev -- true` calls, then 12 `enter dev -- sh -c :`.
    assert_equal "$(_count_calls 'enter dev -- true')" "12"
    assert_equal "$(_count_calls 'enter dev -- sh -c :')" "12"
    assert_equal "$(_calls | wc -l)" "24"
    assert_equal "$(_calls | head -n 1)" "enter dev -- true"
    assert_equal "$(_calls | tail -n 1)" "enter dev -- sh -c :"
    # argv boundaries: `true` is one argument (argc 4), `sh -c :` is three
    # (argc 6) - the shell command is word-split, not passed as one string.
    run sort -u "${FAKE_DBX_CALLS}.argc"
    assert_output "4
6"
}

@test "--box / --runs / --warmup / --shell are honoured in the recorded argv and counts" {
    run "${BENCH}" --box other --runs 3 --warmup 1 --shell "fish -c exit"
    assert_success
    assert_equal "$(_count_calls 'enter other -- true')" "4"
    assert_equal "$(_count_calls 'enter other -- fish -c exit')" "4"
    assert_equal "$(_calls | wc -l)" "8"
    refute_line --partial "dev"
}

@test "--warmup 0 records exactly --runs calls per metric" {
    run "${BENCH}" --runs 2 --warmup 0
    assert_success
    assert_equal "$(_calls | wc -l)" "4"
}

@test "--option=value forms are accepted too" {
    run "${BENCH}" --box=other --runs=2 --warmup=0 --shell="sh -c :"
    assert_success
    assert_equal "$(_count_calls 'enter other -- true')" "2"
    assert_equal "$(_count_calls 'enter other -- sh -c :')" "2"
}

# --- output shape ------------------------------------------------------------

@test "stdout is exactly the two metric lines, enter then shell" {
    local _out="${TMP}/out"
    run bash -c '"$1" --runs 2 --warmup 0 >"$2"' _ "${BENCH}" "${_out}"
    assert_success
    run cat "${_out}"
    assert_equal "${#lines[@]}" 2
    assert_line --index 0 --regexp "$(_metric_re enter)"
    assert_line --index 1 --regexp "$(_metric_re shell)"
}

# --- statistics: ordered, lower-bounded by the sleep, warmup excluded --------

@test "min <= median <= max, each bounded below by the injected sleep, warmup excluded" {
    # Per metric: the 1 warmup call sleeps 300 ms, the 3 recorded runs sleep
    # 10 / 40 / 20 ms -> sorted 10, 20, 40. sleep is a hard lower bound, so
    # min >= 10, median >= 20, max >= 40 (ms); the warmup is excluded, so
    # max stays far below 300 (a 200 ms ceiling leaves a wide margin for a
    # loaded runner).
    run env FAKE_DBX_SLEEP_MS_LIST="300 10 40 20" \
        "${BENCH}" --runs 3 --warmup 1
    assert_success
    local _name _min _med _max
    for _name in enter shell; do
        read -r _min _med _max < <(_metric_tenths "${_name}")
        assert [ "${_min}" -le "${_med}" ]
        assert [ "${_med}" -le "${_max}" ]
        assert [ "${_min}" -ge 100 ]
        assert [ "${_med}" -ge 200 ]
        assert [ "${_max}" -ge 400 ]
        assert [ "${_max}" -lt 2000 ]
    done
}

@test "an even --runs takes the mean of the two middle samples as the median" {
    # Runs sleep 10 / 60 / 20 / 30 ms -> sorted 10, 20, 30, 60: the median
    # is (20 + 30) / 2 = 25 ms, so it lies strictly between the two middle
    # samples (>= 25 by the sleep bound, and, unless the runner stalls for
    # tens of ms, well below the 60 ms max).
    run env FAKE_DBX_SLEEP_MS_LIST="10 60 20 30" "${BENCH}" --runs 4 --warmup 0
    assert_success
    local _min _med _max
    read -r _min _med _max < <(_metric_tenths enter)
    assert [ "${_min}" -ge 100 ]
    assert [ "${_med}" -ge 250 ]
    assert [ "${_med}" -lt "${_max}" ]
    assert [ "${_max}" -ge 600 ]
}

@test "--runs 1 reports min = median = max" {
    run env FAKE_DBX_SLEEP_MS=5 "${BENCH}" --runs 1 --warmup 0
    assert_success
    local _min _med _max
    read -r _min _med _max < <(_metric_tenths enter)
    assert_equal "${_min}" "${_med}"
    assert_equal "${_med}" "${_max}"
    assert [ "${_min}" -ge 50 ]
}

# --- --max-ms threshold ------------------------------------------------------

@test "--max-ms above the shell median exits 0" {
    run env FAKE_DBX_SLEEP_MS=5 "${BENCH}" --runs 3 --warmup 0 --max-ms 5000
    assert_success
    assert_line --regexp "$(_metric_re shell)"
}

@test "--max-ms below the shell median exits 1, still prints both metric lines, says why on stderr" {
    local _out="${TMP}/out" _err="${TMP}/err"
    run bash -c 'env FAKE_DBX_SLEEP_MS=30 "$1" --runs 3 --warmup 0 --max-ms 1 >"$2" 2>"$3"' \
        _ "${BENCH}" "${_out}" "${_err}"
    assert_failure 1
    run cat "${_out}"
    assert_equal "${#lines[@]}" 2
    assert_line --index 0 --regexp "$(_metric_re enter)"
    assert_line --index 1 --regexp "$(_metric_re shell)"
    run cat "${_err}"
    assert_line --regexp '^\[ERROR\] shell median [0-9.]+ ms exceeds --max-ms 1$'
}

@test "--max-ms judges the shell metric only: a slow enter with a fast shell passes" {
    # enter (`-- true`) sleeps 60 ms, shell (`-- sh -c :`) 1 ms; --max-ms 20
    # sits between them, so exit 0 proves the check is on the shell median.
    run env FAKE_DBX_SLEEP_MS_TRUE=60 FAKE_DBX_SLEEP_MS=1 \
        "${BENCH}" --runs 3 --warmup 0 --max-ms 20
    assert_success
    local _min _med _max
    read -r _min _med _max < <(_metric_tenths enter)
    assert [ "${_med}" -ge 600 ]
}

# --- --json ------------------------------------------------------------------

@test "--json prints exactly one JSON object with box, runs, warmup, shell_cmd and both metrics" {
    local _out="${TMP}/out"
    run bash -c 'env FAKE_DBX_SLEEP_MS=2 "$1" --runs 3 --warmup 1 --json >"$2"' \
        _ "${BENCH}" "${_out}"
    assert_success
    run cat "${_out}"
    assert_equal "${#lines[@]}" 1
    assert_output --regexp '^\{.*\}$'
    assert_output --partial '"box":"dev"'
    assert_output --partial '"runs":3'
    assert_output --partial '"warmup":1'
    assert_output --partial '"shell_cmd":"sh -c :"'
    assert_output --partial '"unit":"ms"'
    assert_output --regexp '"enter":\{"min":[0-9.]+,"median":[0-9.]+,"max":[0-9.]+\}'
    assert_output --regexp '"shell":\{"min":[0-9.]+,"median":[0-9.]+,"max":[0-9.]+\}'
    # No plain-text metric line alongside the object.
    refute_output --regexp '^(enter|shell): min='
}

@test "--json escapes a double quote in the box name" {
    run "${BENCH}" --runs 1 --warmup 0 --json --box 'a"b'
    assert_success
    assert_output --partial '"box":"a\"b"'
}

@test "--json with a failing --max-ms still exits 1 after printing the object" {
    run env FAKE_DBX_SLEEP_MS=30 "${BENCH}" --runs 1 --warmup 0 --json --max-ms 1
    assert_failure 1
    assert_line --regexp '^\{.*"shell":\{.*\}$'
}

# --- the tool owns its CLI: --help and unknown / invalid options --------------

@test "--help exits 0, names every option, and calls distrobox nothing" {
    run "${BENCH}" --help
    assert_success
    assert_output --partial "Usage: bench.sh"
    local _opt
    for _opt in --box --runs --warmup --max-ms --json --shell --help; do
        assert_output --partial "${_opt}"
    done
    refute_output --regexp '^(enter|shell): min='
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
    refute_output --regexp '^(enter|shell): min='
    # It stopped at the first failing run: exactly one call was made.
    assert_equal "$(_calls | wc -l)" "1"
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
    run env PATH="${_only}" "${_bash}" "${BENCH}" --runs 1 --warmup 0
    assert_failure 127
    assert_output --partial "[ERROR] distrobox not found on PATH"
    assert_equal "$(_calls)" ""
}
