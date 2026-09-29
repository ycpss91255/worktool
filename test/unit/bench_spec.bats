#!/usr/bin/env bats
# test/unit/bench_spec.bats - script/box/bench.sh enter-latency measurement
# and CLI (M3, issues #150 and #162)
#
# Written test-first (RED) before the tool exists, then bench.sh is
# implemented to pass (GREEN). #162 adds the third metric (inbox) and the
# --box / --shell validation that keeps --json valid JSON, again test-first.
#
# Contract under test:
#   - Three metrics, in this order:
#       enter = `distrobox enter <box> -- true`          host EPOCHREALTIME
#       shell = `distrobox enter <box> -- <shell>`       host EPOCHREALTIME
#               (default `sh -c :`)
#       inbox = `distrobox enter <box> -- bash -c '<timer>' bench-inbox <shell>`
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
#
# HOW
#   A FAKE `distrobox` sits first on PATH. It records every call (one line
#   `$*` per call, and `$#` per call in a sibling file) and sleeps a
#   configurable number of milliseconds: FAKE_DBX_SLEEP_MS for every call;
#   FAKE_DBX_SLEEP_MS_LIST instead gives the k-th call with an identical
#   argv the k-th entry (cycling), so one metric's warmup can be slow and
#   its runs fast, which makes the "warmup excluded" claim checkable;
#   FAKE_DBX_SLEEP_MS_TRUE overrides the sleep for the `-- true` argv only
#   (the enter metric), so the metrics can differ. FAKE_DBX_EXIT injects a
#   failing enter for every call; FAKE_DBX_EXIT_SHELL only for the shell
#   argv and FAKE_DBX_EXIT_INBOX only for the inbox argv, so "enter passes,
#   a later metric fails" is testable. `sleep` never returns early, so a
#   run's measured time is a hard LOWER bound on the requested sleep; upper
#   bounds are only asserted with a wide margin (the runner may be loaded).
#
#   The fake understands the inbox argv (`-- bash -c <timer> ...`, told
#   apart by the EPOCHREALTIME reads in the timer text): it does NOT run the
#   timer, it sleeps like any other call and then prints the microseconds
#   it was told to sleep (FAKE_DBX_INBOX_OUT replaces that line verbatim, to
#   inject garbage). So the inbox numbers are INJECTED, not measured on the
#   host: the fake's stdout is exactly what a real in-box timer prints, and
#   the assertions on the inbox metric can be EXACT (the even-runs median
#   case), unlike the host-clocked enter / shell metrics which only admit
#   lower bounds. Whether the real timer prints what the fake prints is the
#   system-real gate's business (test/system/real_engine_spec.bats).

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
if (( _ms > 0 )); then
    printf -v _s '%d.%03d' $(( _ms / 1000 )) $(( _ms % 1000 ))
    sleep "${_s}"
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

# --- statistics: ordered, lower-bounded by the sleep, warmup excluded --------

@test "min <= median <= max, each bounded below by the injected sleep, warmup excluded" {
    # Per metric: the 1 warmup call sleeps 300 ms, the 3 recorded runs sleep
    # 10 / 40 / 20 ms -> sorted 10, 20, 40. sleep is a hard lower bound, so
    # min >= 10, median >= 20, max >= 40 (ms); the warmup is excluded, so
    # max stays far below 300 (a 200 ms ceiling leaves a wide margin for a
    # loaded runner). The inbox metric gets the same numbers injected.
    run env FAKE_DBX_SLEEP_MS_LIST="300 10 40 20" \
        "${BENCH}" --runs 3 --warmup 1
    assert_success
    local _name _min _med _max
    for _name in enter shell inbox; do
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

@test "an even --runs median is EXACTLY the mean of the two middle samples (inbox: injected in-box times)" {
    # The inbox numbers come from the fake's stdout, not the host clock, so
    # the statistics are deterministic: 10 / 60 / 20 / 30 ms -> min 10.0,
    # median (20 + 30) / 2 = 25.0, max 60.0, to the digit.
    run env FAKE_DBX_SLEEP_MS_LIST="10 60 20 30" "${BENCH}" --runs 4 --warmup 0
    assert_success
    assert_line "inbox: min=10.0 median=25.0 max=60.0 ms"
}

@test "the inbox metric is the in-box number, not the host round trip" {
    # Every call sleeps 40 ms on the host (so enter / shell are >= 40 ms),
    # but the in-box timer reports 1500 us: inbox must print 1.5 ms, i.e.
    # what the box measured, not what the host waited for.
    run env FAKE_DBX_SLEEP_MS=40 FAKE_DBX_INBOX_OUT=1500 \
        "${BENCH}" --runs 3 --warmup 0
    assert_success
    assert_line "inbox: min=1.5 median=1.5 max=1.5 ms"
    local _min _med _max
    read -r _min _med _max < <(_metric_tenths shell)
    assert [ "${_min}" -ge 400 ]
}

@test "--runs 1 reports min = median = max" {
    run env FAKE_DBX_SLEEP_MS=5 "${BENCH}" --runs 1 --warmup 0
    assert_success
    local _name _min _med _max
    for _name in enter shell inbox; do
        read -r _min _med _max < <(_metric_tenths "${_name}")
        assert_equal "${_min}" "${_med}"
        assert_equal "${_med}" "${_max}"
        assert [ "${_min}" -ge 50 ]
    done
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

@test "--max-ms does not judge the inbox metric: a slow in-box time with a fast shell passes" {
    # The in-box timer reports 90 ms while the host round trips take ~1 ms;
    # --max-ms 20 passes, so the gate ignores inbox.
    run env FAKE_DBX_SLEEP_MS=1 FAKE_DBX_INBOX_OUT=90000 \
        "${BENCH}" --runs 3 --warmup 0 --max-ms 20
    assert_success
    assert_line "inbox: min=90.0 median=90.0 max=90.0 ms"
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
    assert_output --partial "\`[INFO] shell: ... of 'distrobox enter dev -- fish -c exit' done\`"
    assert_output --partial "\`[INFO] inbox: ... of 'distrobox enter dev -- bash -c <timer> bench-inbox fish -c exit' done\`"
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
