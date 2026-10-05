#!/usr/bin/env bats
# test/unit/verify_realbox_spec.bats - script/verify/realbox.sh, the M3
# real-machine acceptance items 5.1 / 5.2 / 5.3 (doc/acceptance.md).
#
# WHAT THIS SPEC IS FOR
#   The script replaced three shell blocks that lived inside a markdown
#   document. The defect that motivated the move is not "the checks are
#   wrong" - it is that a BROKEN CHECK COULD READ AS A PASS: a `distrobox
#   list` that failed parsed as "no such box", a `grep -c` that could not
#   open a file printed 0 like a clean file does, a `sha256sum` that died
#   inside a command substitution compared equal to another dead one.
#
#   So every case below breaks ONE stage and asserts the script exits
#   non-zero. The cases that matter most are the ones where the broken stage
#   still prints PLAUSIBLE OUTPUT and only its exit status betrays it - the
#   exact shape the document's blocks used to swallow. Each of those is
#   marked `(plausible output, non-zero exit)` in its name.
#
# HOW
#   test/unit/fixture/realbox_tool.sh is installed as distrobox / just / gh /
#   jq (a fake that keeps a box list and a call log, and can be told to print
#   a convincing answer while exiting non-zero).
#   test/unit/fixture/realbox_shim.sh is installed as grep / cut / wc / sort /
#   sha256sum / readlink / tee / mktemp / id / date / uname / cp / mv / rm /
#   awk: by default it delegates to the REAL tool (recorded before PATH is
#   touched), so only the stage a case names is broken.
#   HOME and TMPDIR point into the test's own tmpdir, so nothing this spec
#   runs can reach the machine's real ghostty or worktool config.

load "${BATS_TEST_DIRNAME}/../helper/common"

@test "realbox: the default box name follows the shipped manifest before opt-in" {
    local _repo="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${_repo}"
    cp -a "${REPO_ROOT}/script" "${REPO_ROOT}/lib" "${REPO_ROOT}/box" "${_repo}/"
    sed -i 's/^\[dev\]$/[acceptance-box]/' "${_repo}/box/dev.ini"
    run "${_repo}/script/verify/realbox.sh" 5.1
    assert_failure 2
    assert_output --partial "named 'acceptance-box'"
    assert_equal "$(_count_calls distrobox)" "0"
}

@test "5.1: an interrupt during bench removes the owned box and exits 130" {
    cp "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${STATE}/just"
    export VERIFY_TOOL="${STATE}/just"
    cat >"${STUBS}/just" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${2:-}" == bench ]]; then
    kill -INT "${VERIFY_PID}"
    exit 0
fi
exec "${VERIFY_TOOL}" "$@"
STUB
    run bash -c 'export VERIFY_PID=$$; exec "$@"' _ "${REALBOX}" --allow-real-box 5.1
    assert_failure 130
    assert_line "cleanup-rc=0"
    [ ! -s "${STATE}/boxes" ]
    assert_equal "$(_count_calls gh)" "0"
}

REALBOX_FAKED_TOOLS=(distrobox just gh jq)
REALBOX_SHIMMED_TOOLS=(grep cut wc sort sha256sum readlink tee mktemp id date uname cp mv rm awk)

setup() {
    REALBOX="${REPO_ROOT}/script/verify/realbox.sh"
    STATE="${BATS_TEST_TMPDIR}/state"
    STUBS="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STATE}/real" "${STUBS}" "${BATS_TEST_TMPDIR}/tmp" \
        "${BATS_TEST_TMPDIR}/home/.config/ghostty"

    : >"${STATE}/boxes"
    : >"${STATE}/calls.log"
    : >"${STATE}/list-calls"

    local _t
    # Resolve the real tools BEFORE PATH changes; the shim execs these.
    for _t in just jq "${REALBOX_SHIMMED_TOOLS[@]}"; do
        command -v -- "${_t}" >"${STATE}/real/${_t}"
    done
    for _t in "${REALBOX_FAKED_TOOLS[@]}"; do
        install -m 0755 "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${STUBS}/${_t}"
    done
    for _t in "${REALBOX_SHIMMED_TOOLS[@]}"; do
        install -m 0755 "${BATS_TEST_DIRNAME}/fixture/realbox_shim.sh" "${STUBS}/${_t}"
    done

    printf 'font-size = 12\n' >"${BATS_TEST_TMPDIR}/home/.config/ghostty/config"

    export FAKE_WORKTOOL_LIB_DIR="${REPO_ROOT}/lib"
    export FAKE_STATE_DIR="${STATE}"
    export HOME="${BATS_TEST_TMPDIR}/home"
    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    unset XDG_CONFIG_HOME
    PATH="${STUBS}:${PATH}"
    export PATH
}

@test "realbox: missing jq is unavailable before any box action" {
    local _path="${BATS_TEST_TMPDIR}/no-jq" _tool
    mkdir -p "${_path}"
    for _tool in bash dirname awk distrobox just gh mktemp timeout grep cut sort wc tee date uname mkdir ln; do
        ln -s "$(command -v "${_tool}")" "${_path}/${_tool}"
    done
    run env PATH="${_path}" "${REALBOX}" --allow-real-box 5.1
    assert_failure 3
    assert_output --partial "[UNAVAILABLE] realbox.sh: jq not found on PATH"
    refute_output --partial "[FAIL]"
    assert_equal "$(_count_calls distrobox)" "0"
}

@test "5.3: missing backup tool remains unavailable through decoy cleanup" {
    local _path="${BATS_TEST_TMPDIR}/no-cp" _tool
    mkdir -p "${_path}"
    for _tool in bash dirname awk distrobox just gh jq mktemp timeout grep cut sort wc tee date uname mkdir ln find cmp sha256sum mv rm readlink id rmdir; do
        ln -s "$(command -v "${_tool}")" "${_path}/${_tool}"
    done
    run env PATH="${_path}" "${REALBOX}" --allow-real-box 5.3
    assert_failure 3
    assert_output --partial "[UNAVAILABLE] realbox.sh: cp not found on PATH"
    assert_line 'decoy-cleanup-rc=0'
    [ ! -s "${STATE}/boxes" ]
}

@test "5.2: missing apply tool stays unavailable when restore also cannot run" {
    local _path="${BATS_TEST_TMPDIR}/no-distrobox" _tool
    mkdir -p "${_path}"
    for _tool in bash dirname awk just gh jq mktemp timeout grep cut sort wc tee date uname mkdir ln find cmp sha256sum cp mv rm readlink id rmdir cat ps; do
        ln -s "$(command -v "${_tool}")" "${_path}/${_tool}"
    done
    run env PATH="${_path}" "${REALBOX}" --allow-real-box 5.2
    assert_failure 3
    assert_output --partial "[UNAVAILABLE] realbox.sh: distrobox not found on PATH"
    refute_output --partial "[FAIL] item 5.2 failed"
    assert_equal "$(_count_calls just)" "0"
}

@test "5.3: an unavailable refusal check cannot count as a product refusal" {
    local _path="${BATS_TEST_TMPDIR}/no-wc" _tool
    mkdir -p "${_path}"
    for _tool in bash dirname awk distrobox just gh jq mktemp timeout grep cut sort tee date uname mkdir ln find cmp sha256sum cp mv rm readlink id rmdir cat ps; do
        ln -s "$(command -v "${_tool}")" "${_path}/${_tool}"
    done
    run env PATH="${_path}" "${REALBOX}" --allow-real-box 5.3
    assert_failure 3
    assert_output --partial "[UNAVAILABLE] realbox.sh: wc not found on PATH"
    assert_line 'decoy-cleanup-rc=0'
    [ ! -s "${STATE}/boxes" ]
}

@test "stub contract: failing stream shims drain pipeline input before answering" {
    local _tool _probe="${BATS_TEST_TMPDIR}/stream-probe.sh"
    cat >"${_probe}" <<'EOF'
set -o pipefail
printf '%1048576s\n' x | "$1"
statuses=("${PIPESTATUS[@]}")
printf 'writer=%s reader=%s\n' "${statuses[@]}"
EOF
    for _tool in cut sort wc tee; do
        run env "SHIM_${_tool^^}_RC=1" "SHIM_${_tool^^}_OUT=plausible" \
            bash "${_probe}" "${_tool}"
        assert_success
        assert_line 'plausible'
        assert_line 'writer=0 reader=1'
    done
}

# --- helpers (pure bash: the shims may be told to break coreutils) -----------

# Number of logged calls whose line starts with "$1 ".
_count_calls() {
    local _n=0 _l
    while IFS= read -r _l; do
        case "${_l}" in "$1 "*) _n=$((_n + 1)) ;; esac
    done <"${STATE}/calls.log"
    printf '%s\n' "${_n}"
}

_count_list_calls() {
    local _n=0 _l
    while IFS= read -r _l; do
        case "${_l}" in "distrobox list"*) _n=$((_n + 1)) ;; esac
    done <"${STATE}/calls.log"
    printf '%s\n' "${_n}"
}

_seed_box() { printf '%s\n' "$1" >>"${STATE}/boxes"; }

_ghostty_config() { printf '%s\n' "${HOME}/.config/ghostty/config"; }

_backup_dir() { printf '%s\n' "${TMPDIR}/worktool-m3-52-backup.$(id -u)"; }

# Run realbox.sh for real (not under `run`), so $output stays whatever the
# case under test put there.
_realbox_quiet() { "${REALBOX}" --allow-real-box "$@" >/dev/null 2>&1; }

_reset_log() {
    : >"${STATE}/calls.log"
    : >"${STATE}/list-calls"
}

_distrobox_conf() { printf '%s\n' "${HOME}/.config/distrobox/distrobox.conf"; }

# The user lines distrobox.conf is seeded with: the host distrobox
# configuration stands for, and what every check below asks to survive.
DISTROBOX_USER_LINES=(
    '# worktool acceptance: user content that must survive every write'
    'container_manager=docker'
    'container_always_pull=0'
)

_seed_distrobox_conf() {
    mkdir -p "${HOME}/.config/distrobox"
    printf '%s\n' "${DISTROBOX_USER_LINES[@]}" >"$(_distrobox_conf)"
}

# A user-owned config entry that setup must retain.
_seed_shared_state() {
    mkdir -p "${HOME}/.config/worktool"
    printf 'link=.ssh\n' >"${HOME}/.config/worktool/config"
}

# --- the degraded-copy family ------------------------------------------------
# The fakes above break the TOOLS realbox.sh drives. These break the PRODUCT:
# a copy of the checkout is degraded and `just box setup` / `just box status`
# are pointed at THAT copy (FAKE_JUST_BOX_SCRIPT_DIR), so the output is what
# the degraded product really prints and 5.2 has to catch it on content alone.

_repo_copy() {
    local _dst="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${_dst}"
    cp -a "${REPO_ROOT}/justfile" "${REPO_ROOT}/lib" "${REPO_ROOT}/script" \
        "${REPO_ROOT}/box" "${_dst}/"
    printf '%s\n' "${_dst}"
}

# Insert the lines on stdin into file $2 immediately before its first line
# equal to $1, so a later definition of a shell function shadows the shipped
# one. Pure bash; the result is copied back INTO the file so it keeps its
# executable bit.
_insert_before() {
    local _anchor="$1" _file="$2" _frag _line _done=0
    _frag="$(cat)"
    : >"${_file}.new"
    while IFS= read -r _line || [ -n "${_line}" ]; do
        if [ "${_done}" -eq 0 ] && [ "${_line}" = "${_anchor}" ]; then
            printf '%s\n' "${_frag}" >>"${_file}.new"
            _done=1
        fi
        printf '%s\n' "${_line}" >>"${_file}.new"
    done <"${_file}"
    [ "${_done}" -eq 1 ] || return 1
    cat "${_file}.new" >"${_file}"
    rm -f "${_file}.new"
}

# Only the distrobox isolation write overwrites user content.
_degrade_distrobox_overwrites() {
    _insert_before 'setup_run() {' "$1/script/box/setup.sh" <<'FRAG'
_apply_box_env() {
    local _file _body
    _file="$(enter_distrobox_conf)"
    _body="$(enter_distrobox_conf_body "${BOX}")"
    printf '%s\n%s\n%s\n' "${ENTER_BLOCK_BEGIN}" "${_body}" "${ENTER_BLOCK_END}" >"${_file}" || return 1
    log_info "wrote: ${_file} (managed block: ${_body})"
}
FRAG
}

# --- self-registration -------------------------------------------------------



# --- CLI and the realbox opt-in ----------------------------------------------

@test "--help exits 0 and documents the items and the opt-in flag" {
    run "${REALBOX}" --help
    assert_success
    assert_output --partial "--allow-real-box"
    assert_output --partial "5.1"
    assert_output --partial "5.2.3"
    assert_output --partial "5.3"
    assert_equal "$(_count_calls distrobox)" "0"
}

@test "-h is the same as --help and exits 0" {
    run "${REALBOX}" -h
    assert_success
    assert_output --partial "Usage: realbox.sh"
}

@test "an unknown option exits 2 with a message naming it, and nothing runs" {
    run "${REALBOX}" --allow-real-box --bogus 5.1
    assert_equal "${status}" "2"
    assert_output --partial "realbox.sh: unknown option '--bogus' (see --help)"
    assert_equal "$(_count_calls distrobox)" "0"
    assert_equal "$(_count_calls just)" "0"
}

@test "an unknown item exits 2 with a message naming it" {
    run "${REALBOX}" --allow-real-box 9.9
    assert_equal "${status}" "2"
    assert_output --partial "unknown item '9.9'"
    assert_equal "$(_count_calls distrobox)" "0"
}

@test "an invalid --box value exits 2 before anything runs" {
    run "${REALBOX}" --allow-real-box --box 'dev;rm -rf /' 5.1
    assert_equal "${status}" "2"
    assert_output --partial "invalid --box"
    assert_equal "$(_count_calls distrobox)" "0"
}

@test "without --allow-real-box the realbox group refuses and touches nothing" {
    run "${REALBOX}" 5.1
    assert_equal "${status}" "2"
    assert_output --partial "Pass --allow-real-box"
    assert_equal "$(_count_calls distrobox)" "0"
    assert_equal "$(_count_calls just)" "0"
    assert_equal "$(_count_calls gh)" "0"
}

# --- 5.1 real-machine bench --------------------------------------------------

@test "5.1: --comment-tag prefixes the first body.md line" {
    run "${REALBOX}" --allow-real-box --comment-tag '[claude]' 5.1
    assert_success
    local _first
    IFS= read -r _first <"${STATE}/last-comment-body"
    [[ "${_first}" == '[claude] M3 5.1 real-machine bench ('* ]]
}

@test "5.1: read-back requires the comment tag at the start of the body" {
    # Exercise the actual jq verdict with this run's posted body and metrics.
    cp "${STUBS}/gh" "${STATE}/gh"
    ln -sf "$(cat "${STATE}/real/jq")" "${STUBS}/jq"
    cat >"${STUBS}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == api ]]; then
    jq -n --rawfile body "${FAKE_STATE_DIR}/last-comment-body" \
        --arg prefix "${READ_BACK_PREFIX:-}" \
        '{issue_url: "https://api.github.com/repos/ycpss91255/worktool/issues/22",
          body: ($prefix + $body)}'
else
    exec "${FAKE_STATE_DIR}/gh" "$@"
fi
STUB
    run "${REALBOX}" --allow-real-box --comment-tag '[claude]' 5.1
    assert_success
    assert_line --partial 'posted=1 comment=9001'
    READ_BACK_PREFIX='unexpected text ' \
        run "${REALBOX}" --allow-real-box --comment-tag '[claude]' 5.1
    assert_failure 1
    assert_line --partial 'posted=0 comment=9001'
    assert_line 'cleanup-rc=0'
}

@test "5.1 happy path prints the documented lines and exits 0" {
    run "${REALBOX}" --allow-real-box 5.1
    assert_success
    assert_line "preexisting-dev=0"
    assert_line "enter: min=136.1 median=171.1 max=197.0 ms"
    assert_line "shell: min=143.8 median=176.9 max=215.5 ms"
    assert_line "inbox: min=14.9 median=17.5 max=25.4 ms"
    assert_line "rc=0"
    assert_line --partial "posted=1 comment=9001 run=m3-51-"
    assert_line "cleanup-rc=0"
}

@test "5.1: distrobox list prints a plausible table but exits 1 (plausible output, non-zero exit)" {
    _seed_box other
    FAKE_DBX_LIST_RC=1 run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "cannot tell whether 'dev' exists"
    refute_output --partial "preexisting-dev=0"
    assert_equal "$(_count_calls just)" "0"
}

@test "5.1: awk fails, so the listing cannot be parsed - that is not 'no such box'" {
    SHIM_AWK_RC=2 run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "cannot tell whether 'dev' exists"
    assert_equal "$(_count_calls just)" "0"
}

@test "5.1: a pre-existing dev box is refused before assemble, and never deleted" {
    _seed_box dev
    run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "a distrobox named 'dev' already exists -- refusing"
    refute_output --partial "preexisting-dev=0"
    refute_output --partial "cleanup-rc"
    assert_equal "$(_count_calls just)" "0"
}

@test "5.1: just box assemble fails, and cleanup still runs" {
    FAKE_JUST_ASSEMBLE_RC=1 run "${REALBOX}" --allow-real-box 5.1
    assert_failure 1
    assert_output --partial "just box assemble failed"
    assert_line "cleanup-rc=0"
}

@test "5.1: assemble returns 0 but the box is not listed" {
    FAKE_JUST_ASSEMBLE_REGISTERS=0 run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "assemble returned 0 but box 'dev' is not listed"
}

@test "5.1: bench prints the three metric lines but exits 1 (plausible output, non-zero exit)" {
    FAKE_JUST_BENCH_RC=1 run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    # The output looks exactly like a pass; only rc= and the status differ.
    assert_line "enter: min=136.1 median=171.1 max=197.0 ms"
    assert_line "rc=1"
    assert_output --partial "just box bench exited 1"
    refute_output --partial "posted="
}

@test "5.1: tee prints the bench output but exits 1 (plausible output, non-zero exit)" {
    SHIM_TEE_RC=1 \
        SHIM_TEE_OUT='enter: min=1.0 median=1.0 max=1.0 ms' \
        run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_line "rc=0"
    assert_output --partial "the captured bench output is not trustworthy"
    refute_output --partial "posted="
}

@test "5.1: grep cannot read the bench output (exit 2) and that is not zero matches" {
    SHIM_GREP_RC=2 SHIM_GREP_OUT='enter: min=1.0 median=1.0 max=1.0 ms' \
        run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "grep exited 2"
    refute_output --partial "posted="
}

@test "5.1: only two metric lines is refused" {
    FAKE_JUST_BENCH_OUT='enter: min=1.0 median=1.0 max=1.0 ms
shell: min=2.0 median=2.0 max=2.0 ms' \
        run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "got n=2 distinct=2"
}

@test "5.1: three lines of the SAME metric is refused (n=3 is not enough)" {
    FAKE_JUST_BENCH_OUT='shell: min=1.0 median=1.0 max=1.0 ms
shell: min=2.0 median=2.0 max=2.0 ms
shell: min=3.0 median=3.0 max=3.0 ms' \
        run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "got n=3 distinct=1"
}

@test "5.1: three shaped numbers that are not ordered min <= median <= max are refused" {
    # One line per metric, every number well formed, exactly the shape the old
    # check accepted - and min > max, so it is not a measurement of anything.
    FAKE_JUST_BENCH_OUT='enter: min=500 median=400 max=1 ms
shell: min=143.8 median=176.9 max=215.5 ms
inbox: min=14.9 median=17.5 max=25.4 ms' \
        run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "enter: min=500 median=400 max=1 is not min <= median <= max"
    refute_output --partial "posted="
}

@test "5.1: a shell median above the --max-ms the run passed to bench is refused" {
    # Inside its own line (min <= median <= max) and still over the 300 ms
    # budget this very run handed to `just box bench`.
    FAKE_JUST_BENCH_OUT='enter: min=136.1 median=171.1 max=197.0 ms
shell: min=143.8 median=400.5 max=515.5 ms
inbox: min=14.9 median=17.5 max=25.4 ms' \
        run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "shell median 400.5 ms exceeds the --max-ms 300"
    refute_output --partial "posted="
}

@test "5.1: a shell median exactly at the --max-ms 300 passes (#181: <= passes)" {
    FAKE_JUST_BENCH_OUT='enter: min=136.1 median=171.1 max=197.0 ms
shell: min=143.8 median=300.0 max=315.5 ms
inbox: min=14.9 median=17.5 max=25.4 ms' \
        run "${REALBOX}" --allow-real-box 5.1
    assert_success
    assert_line "rc=0"
    assert_line --partial "posted=1 comment=9001 run=m3-51-"
    refute_output --partial "shell median 300.0 ms"
}

@test "5.1: a shell median of 300.1 ms, just over the --max-ms 300, is refused" {
    FAKE_JUST_BENCH_OUT='enter: min=136.1 median=171.1 max=197.0 ms
shell: min=143.8 median=300.1 max=315.5 ms
inbox: min=14.9 median=17.5 max=25.4 ms' \
        run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "shell median 300.1 ms exceeds the --max-ms 300"
    refute_output --partial "posted="
}

@test "5.1: wc prints a plausible 3 but exits 1 (plausible output, non-zero exit)" {
    SHIM_WC_RC=1 SHIM_WC_OUT='3' run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "counting the bench lines failed"
    refute_output --partial "posted="
}

@test "5.1: cut fails inside the distinct-metric pipeline, whose last stage still prints 3" {
    SHIM_CUT_ON='-d: -f1' SHIM_CUT_RC=1 SHIM_CUT_OUT='enter' \
        run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "counting the distinct bench metrics failed"
    refute_output --partial "posted="
}

@test "5.1: gh issue comment prints a plausible URL but exits 1 (plausible output, non-zero exit)" {
    FAKE_GH_COMMENT_RC=1 run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "gh issue comment failed"
    refute_output --partial "posted="
}

@test "5.1: a comment URL with no numeric id is refused" {
    FAKE_GH_COMMENT_OUT='https://github.com/ycpss91255/worktool/issues/22' \
        run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "cannot parse a comment id out of"
}

@test "5.1: gh api prints plausible JSON but exits 1 (plausible output, non-zero exit)" {
    FAKE_GH_API_RC=1 FAKE_GH_API_OUT='{"issue_url":"x","body":"y"}' \
        run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "re-reading comment 9001 failed"
    refute_output --partial "posted="
}

@test "5.1: jq prints 1 but exits 1 (plausible output, non-zero exit)" {
    FAKE_JQ_RC=1 FAKE_JQ_OUT=1 run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "judging comment 9001 failed"
    refute_output --partial "posted=1"
}

@test "5.1: jq answers 0, so posted=0 and the item fails" {
    FAKE_JQ_OUT=0 run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_line --partial "posted=0 comment=9001"
    assert_output --partial "does not carry run id"
}

@test "5.1: a verdict that is neither 0 nor 1 is refused" {
    FAKE_JQ_OUT='true' run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_output --partial "is 'true', neither 0 nor 1"
}

@test "5.1: the box survives cleanup, so the item fails even though every check passed" {
    FAKE_DBX_RM_REMOVES=0 run "${REALBOX}" --allow-real-box 5.1
    assert_failure
    assert_line --partial "posted=1"
    assert_line "cleanup-rc=1"
    assert_output --partial "survived cleanup"
}

# --- 5.2 step 1: back up -----------------------------------------------------

_install_restore_window_tools() {
    [[ ! -f "${STATE}/restore-apply/ps" ]] || return 0
    mkdir -p "${STATE}/restore-apply"
    if [[ -f "${STUBS}/ps" ]]; then
        cp "${STUBS}/ps" "${STATE}/restore-apply/ps"
    else
        export REAL_WINDOW_PS
        REAL_WINDOW_PS="$(command -v ps)"
        cat >"${STATE}/restore-apply/ps" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
exec "${REAL_WINDOW_PS}" "$@"
STUB
        chmod +x "${STATE}/restore-apply/ps"
    fi
    cp "${STUBS}/readlink" "${STATE}/restore-apply/readlink"
    cat >"${STUBS}/ps" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    '-p 4344 -o comm=') printf 'fish\n' ;;
    '-p 4344 -o ppid=,args=') printf '900 /usr/bin/fish\n' ;;
    '-p 900 -o ppid=,args=') printf '1 /usr/bin/ghostty\n' ;;
    *) exec "${FAKE_STATE_DIR}/restore-apply/ps" "$@" ;;
esac
STUB
    cat >"${STUBS}/readlink" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == /proc/4344/ns/mnt ]]; then
    exec "${FAKE_STATE_DIR}/restore-apply/readlink" /proc/self/ns/mnt
fi
exec "${FAKE_STATE_DIR}/restore-apply/readlink" "$@"
STUB
    chmod +x "${STUBS}/ps" "${STUBS}/readlink"
}

_window_input() {
    cat >"${STATE}/window-run" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
rc=0
"${REALBOX}" --allow-real-box 5.2 || rc=$?
printf '%s\n' "${rc}" >"${FAKE_STATE_DIR}/window-rc"
STUB
    chmod +x "${STATE}/window-run"
    _install_restore_window_tools
    printf '%s\n' "$1" 4344 | script -q -c \
        "\"${STATE}/window-run\"" /dev/null
}

@test "#362: 5.2 refuses typed yes without objective window evidence" {
    export REALBOX
    run _window_input yes
    assert_equal "$(cat "${STATE}/window-rc")" "1"
    assert_output --partial "expected a fish PID"
    refute_output --partial "container-marker=confirmed"
    assert_output --partial "restore-ok=1"
    assert_output --partial "backup-removed=1"
}

_fake_window_process() {
    cat >"${STUBS}/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'exec dev readlink /proc/self/ns/mnt' ]] || exit 2
printf '%s\n' "${FAKE_DEV_NS-mnt:[200]}"
exit "${FAKE_DEV_NS_RC:-0}"
STUB
    chmod +x "${STUBS}/docker"
    export DBX_CONTAINER_MANAGER=docker
    cat >"${STUBS}/ps" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == '-e -o pid=,comm=' ]]; then
    printf '%s\n' "${FAKE_WINDOW_BASELINE:-1 init}"
    exit "${FAKE_WINDOW_BASELINE_RC:-0}"
fi
printf '%s\n' "${FAKE_WINDOW_COMM:-fish}"
exit "${FAKE_WINDOW_PS_RC:-0}"
STUB
    mv "${STUBS}/readlink" "${STATE}/readlink"
    cat >"${STUBS}/readlink" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    /proc/self/ns/mnt) printf 'mnt:[100]\n' ;;
    /proc/4343/ns/mnt)
        printf '%s\n' "${FAKE_DEV_NS-mnt:[200]}"
        exit "${FAKE_DEV_NS_RC:-0}" ;;
    /proc/4242/ns/mnt)
        printf '%s\n' "${FAKE_WINDOW_NS-mnt:[200]}"
        exit "${FAKE_WINDOW_NS_RC:-0}" ;;
    *) exec "${FAKE_STATE_DIR}/readlink" "$@" ;;
esac
STUB
    chmod +x "${STUBS}/ps" "${STUBS}/readlink"
    export REALBOX
}

@test "#362: 5.2 refuses an existing fish process as new-window evidence" {
    _fake_window_process
    export FAKE_WINDOW_BASELINE='4242 fish'
    run _window_input 4242
    assert_equal "$(cat "${STATE}/window-rc")" "1"
    assert_output --partial "fish PID 4242 existed before setup"
    assert_output --partial "restore-ok=1"
    export FAKE_WINDOW_BASELINE_RC=1
    run _window_input 4242
    assert_equal "$(cat "${STATE}/window-rc")" "1"
    assert_output --partial "cannot inventory processes before setup"
    assert_output --partial "restore-files-ok=1"
    assert_output --partial "restore-ok=0"
}

@test "#362: 5.2 explains asynchronous reload for an already running Ghostty" {
    export REALBOX
    run _window_input yes
    assert_output --partial "Ghostty already running"
    assert_output --partial "Ctrl+Shift+,"
    assert_output --partial "asynchronous"
    assert_output --partial "config.ghostty"
    assert_output --partial "start a new Ghostty process"
    assert_output --partial "Never close your existing windows"
    assert_output --partial "echo \$fish_pid"
}

@test "#362: realbox help names the four actual backup files" {
    run "${REALBOX}" --help
    assert_success
    assert_output --partial "Ghostty legacy config"
    assert_output --partial "config.ghostty"
    assert_output --partial "worktool state file"
    assert_output --partial "distrobox.conf"
    refute_output --partial ".tmux.conf"
    assert_output --partial "fish mount namespace"
}

_fake_unreadable_dev_init() {
    _fake_window_process
    export FAKE_DEV_NS=''
    cat >"${STUBS}/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    'inspect --type container --format {{.State.Pid}} dev') printf '4343\n' ;;
    'exec dev readlink /proc/self/ns/mnt')
        printf '%s\n' "${FAKE_ENGINE_NS-mnt:[200]}"
        exit "${FAKE_ENGINE_EXEC_RC:-0}" ;;
    *) exit 2 ;;
esac
STUB
}

@test "#469: 5.2 accepts matching engine namespace when host dev init is unreadable" {
    _fake_unreadable_dev_init
    run _window_input 4242
    assert_equal "$(cat "${STATE}/window-rc")" "0"
    assert_output --partial "window-evidence: pid=4242 comm=fish host=mnt:[100] window=mnt:[200] dev=mnt:[200]"
    assert_output --partial "restore-ok=1"
    assert_output --partial "backup-removed=1"
}

@test "#469: 5.2 rejects mismatching engine namespace when host dev init is unreadable" {
    _fake_unreadable_dev_init
    export FAKE_ENGINE_NS='mnt:[300]'
    run _window_input 4242
    assert_equal "$(cat "${STATE}/window-rc")" "1"
    assert_output --partial "fish mount namespace does not match dev"
    refute_output --partial "window-evidence: pid=4242"
    assert_output --partial "restore-ok=1"
    assert_output --partial "dev-gone=1"
    assert_output --partial "backup-removed=1"
}

@test "#469: 5.2 rejects failed engine exec despite matching output and unreadable host dev init" {
    _fake_unreadable_dev_init
    export FAKE_ENGINE_EXEC_RC=1
    run _window_input 4242
    assert_equal "$(cat "${STATE}/window-rc")" "1"
    assert_output --partial "cannot read dev mount namespace; check the container engine and re-run 5.2"
    refute_output --partial "window-evidence: pid=4242"
    assert_output --partial "restore-ok=1"
    assert_output --partial "dev-gone=1"
    assert_output --partial "backup-removed=1"
}

@test "#433: 5.2 passes with a new fish in this runs dev namespace" {
    _fake_window_process
    run _window_input 4242
    assert_equal "$(cat "${STATE}/window-rc")" "0"
    assert_output --partial "window-evidence: pid=4242 comm=fish host=mnt:[100] window=mnt:[200] dev=mnt:[200]"
    refute_output --partial "container-marker=confirmed"
    assert_output --partial "restore-ok=1"
    local _mode
    for _mode in host non-fish ps-failed namespace-failed empty malformed; do
        unset FAKE_WINDOW_COMM FAKE_WINDOW_PS_RC FAKE_WINDOW_NS FAKE_WINDOW_NS_RC
        case "${_mode}" in
            host) export FAKE_WINDOW_NS='mnt:[100]' ;;
            non-fish) export FAKE_WINDOW_COMM=sh ;;
            ps-failed) export FAKE_WINDOW_PS_RC=1 ;;
            namespace-failed) export FAKE_WINDOW_NS_RC=1 ;;
            empty) export FAKE_WINDOW_NS='' ;;
            malformed) export FAKE_WINDOW_NS='different' ;;
        esac
        run _window_input 4242
        assert_equal "$(cat "${STATE}/window-rc")" "1"
        refute_output --partial "container-marker=confirmed"
        assert_output --partial "restore-ok=1"
    done
}

@test "#433: 5.2 rejects a fresh fish in another container and restores" {
    _fake_window_process
    FAKE_WINDOW_NS='mnt:[300]' run _window_input 4242
    assert_equal "$(cat "${STATE}/window-rc")" "1"
    assert_output --partial "fish mount namespace does not match dev"
    refute_output --partial "window-evidence: pid=4242"
    assert_output --partial "restore-ok=1"
    assert_output --partial "dev-gone=1"
    assert_output --partial "backup-removed=1"
}

@test "#433: 5.2 rejects an unresolvable dev namespace and restores" {
    _fake_window_process
    local _mode
    for _mode in unreadable empty malformed; do
        unset FAKE_DEV_NS_RC FAKE_DEV_NS
        case "${_mode}" in
            unreadable) export FAKE_DEV_NS_RC=1 ;;
            empty) export FAKE_DEV_NS='' ;;
            malformed) export FAKE_DEV_NS=unknown ;;
        esac
        run _window_input 4242
        assert_equal "$(cat "${STATE}/window-rc")" "1"
        refute_output --partial "window-evidence: pid=4242"
        assert_output --partial "restore-ok=1"
        assert_output --partial "dev-gone=1"
        assert_output --partial "backup-removed=1"
    done
}

@test "5.2.1 happy path records every file setup can write and publishes the manifest" {
    _seed_distrobox_conf
    run "${REALBOX}" --allow-real-box 5.2.1
    assert_success
    assert_line "backup-covers=4/4"
    assert_line "ghostty=regular"
    assert_line --partial "ghostty.sha="
    assert_line "worktool=absent-dir"
    # distrobox.conf is in the set: every setup maintains it, and step 3 would
    # have nothing to restore it from.
    assert_line "distrobox-conf=regular"
    assert_line --partial "distrobox-conf.sha="
    assert_line "backup=$(_backup_dir) ok=1"
    [ -f "$(_backup_dir)/manifest" ]
    [ -f "$(_backup_dir)/distrobox-conf.config" ]
}

@test "5.2.1: an absent distrobox directory is recorded for removal" {
    run "${REALBOX}" --allow-real-box 5.2.1
    assert_success
    assert_line "backup-covers=4/4"
    assert_line "distrobox-conf=absent-dir"
}

@test "5.2.1 refuses the whole item when a file setup can write cannot be backed up" {
    # A directory where distrobox.conf should be: `just box setup`
    # would still try to write there, and nothing could put it back. The
    # refusal lands BEFORE a backup directory exists.
    mkdir -p "$(_distrobox_conf)"
    run "${REALBOX}" --allow-real-box 5.2.1
    assert_failure
    assert_line "backup-covers=3/4"
    assert_output --partial "neither a regular file nor a symlink"
    assert_output --partial "refusing to apply anything"
    [ ! -e "$(_backup_dir)" ]
}

@test "5.2.1 refuses when the link behind a config leads somewhere it cannot copy" {
    # A symlinked distrobox.conf whose target is a directory: `cp -a` would
    # copy the link, and the file behind it - the one that actually holds
    # the user's configuration - could not be preserved at all.
    mkdir -p "${BATS_TEST_TMPDIR}/not-a-file"
    mkdir -p "${HOME}/.config/distrobox"
    ln -s "${BATS_TEST_TMPDIR}/not-a-file" "$(_distrobox_conf)"
    run "${REALBOX}" --allow-real-box 5.2.1
    assert_failure
    assert_line "backup-covers=3/4"
    assert_output --partial "is not a regular file -- handle it by hand"
    [ ! -e "$(_backup_dir)" ]
}

@test "5.2.1: an existing backup dir is refused with ok=0 and nothing is copied" {
    mkdir -p "$(_backup_dir)"
    run "${REALBOX}" --allow-real-box 5.2.1
    assert_failure
    assert_line "backup=$(_backup_dir) ok=0"
    assert_output --partial "backup dir already exists"
    [ ! -e "$(_backup_dir)/manifest" ]
}

@test "5.2.1: sha256sum prints a plausible hash but exits 1 (plausible output, non-zero exit)" {
    SHIM_SHA256SUM_RC=1 \
        SHIM_SHA256SUM_OUT='0000000000000000000000000000000000000000000000000000000000000000  x' \
        run "${REALBOX}" --allow-real-box 5.2.1
    assert_failure
    assert_output --partial "hashing the backup failed"
    assert_line --partial "ok=0"
    [ ! -e "$(_backup_dir)" ]
}

@test "5.2.1: sha256sum exits 0 but prints something that is not a sha256" {
    SHIM_SHA256SUM_RC=0 SHIM_SHA256SUM_OUT='(stdin)= deadbeef  x' \
        run "${REALBOX}" --allow-real-box 5.2.1
    assert_failure
    assert_output --partial "hashing the backup failed"
    [ ! -e "$(_backup_dir)" ]
}

@test "5.2.1: publishing the manifest fails, so nothing is left half-published" {
    SHIM_MV_RC=1 run "${REALBOX}" --allow-real-box 5.2.1
    assert_failure
    assert_output --partial "publishing the manifest failed"
    assert_line --partial "ok=0"
    [ ! -e "$(_backup_dir)" ]
}

@test "5.2.1: readlink failing on a symlinked config is refused, not read as 'the links match'" {
    rm -f "$(_ghostty_config)"
    printf 'font-size = 9\n' >"${HOME}/.config/ghostty/real-config"
    ln -s "${HOME}/.config/ghostty/real-config" "$(_ghostty_config)"
    # Scoped to the BACKUP copy's link, so the preflight (which resolves the
    # live link) still runs and this case reaches the guard it is about.
    SHIM_READLINK_ON='worktool-m3-52-backup' SHIM_READLINK_RC=1 SHIM_READLINK_OUT='' \
        run "${REALBOX}" --allow-real-box 5.2.1
    assert_failure
    assert_output --partial "cannot read the backup link"
    [ ! -e "$(_backup_dir)" ]
}

@test "5.2.1: a link this run cannot resolve refuses before a backup directory exists" {
    rm -f "$(_ghostty_config)"
    printf 'font-size = 9\n' >"${HOME}/.config/ghostty/real-config"
    ln -s "${HOME}/.config/ghostty/real-config" "$(_ghostty_config)"
    SHIM_READLINK_RC=1 SHIM_READLINK_OUT='' run "${REALBOX}" --allow-real-box 5.2.1
    assert_failure
    assert_line "backup-covers=3/4"
    assert_output --partial "cannot resolve the link"
    [ ! -e "$(_backup_dir)" ]
}

# --- 5.2 step 2: re-validate, then apply -------------------------------------

@test "5.2.2 happy path re-validates the published backup and applies" {
    _realbox_quiet 5.2.1
    run "${REALBOX}" --allow-real-box 5.2.2
    assert_success
    assert_line "revalidate=1"
    assert_line "preexisting-dev=0"
    assert_line "setup-rc=0"
    [ -e "$(_backup_dir)/created-box" ]
}

@test "5.2.2: no published manifest means nothing is applied" {
    run "${REALBOX}" --allow-real-box 5.2.2
    assert_failure
    assert_output --partial "no published manifest"
    refute_output --partial "revalidate=1"
    assert_equal "$(_count_calls just)" "0"
}

@test "5.2.2: a leftover manifest.partial means step 1 is half-done" {
    _realbox_quiet 5.2.1
    : >"$(_backup_dir)/manifest.partial"
    run "${REALBOX}" --allow-real-box 5.2.2
    assert_failure
    assert_output --partial "still present -- step 1 is half-done"
    assert_equal "$(_count_calls just)" "0"
}

@test "5.2.2: a live config changed since step 1 is refused" {
    _realbox_quiet 5.2.1
    printf 'font-size = 99\n' >"$(_ghostty_config)"
    run "${REALBOX}" --allow-real-box 5.2.2
    assert_failure
    assert_output --partial "live config changed since step 1"
    assert_equal "$(_count_calls just)" "0"
}

@test "5.2.2: grep cannot read the manifest (exit 2) and that is not 'zero state lines'" {
    _realbox_quiet 5.2.1
    SHIM_GREP_ON='^ghostty=' SHIM_GREP_RC=2 SHIM_GREP_OUT='0' \
        run "${REALBOX}" --allow-real-box 5.2.2
    assert_failure
    assert_output --partial "cannot count the manifest state lines"
    refute_output --partial "revalidate=1"
}

@test "5.2.2: a pre-existing dev box is refused after revalidate=1 and before assemble" {
    _realbox_quiet 5.2.1
    _seed_box dev
    run "${REALBOX}" --allow-real-box 5.2.2
    assert_failure
    assert_line "revalidate=1"
    assert_output --partial "Step 3 deletes the box this run creates"
    refute_output --partial "preexisting-dev=0"
    assert_equal "$(_count_calls just)" "0"
    [ ! -e "$(_backup_dir)/created-box" ]
}

@test "5.2.2: just box setup prints plausible output but exits 1 (plausible output, non-zero exit)" {
    _realbox_quiet 5.2.1
    FAKE_JUST_SETUP_RC=1 FAKE_JUST_SETUP_OUT='auto-enter: yes (default)' \
        run "${REALBOX}" --allow-real-box 5.2.2
    assert_failure
    assert_output --partial "just box setup failed"
    refute_output --partial "setup-rc=0"
}

# --- 5.2 step 3: restore -----------------------------------------------------

@test "5.2.3 with no backup is a no-op that exits 0" {
    bats_require_minimum_version 1.5.0
    run --separate-stderr "${REALBOX}" --allow-real-box 5.2.3
    assert_success
    assert_line "no-backup=1"
    assert_output "no-backup=1"
    assert_equal "${stderr:-}" "[INFO] $(_backup_dir) absent; already restored, or step 1 never ran"
    assert_equal "$(_count_calls just)" "0"
}

@test "5.2.3: a backup dir with no published manifest is reported, not restored" {
    mkdir -p "$(_backup_dir)"
    run _restore_input 4242
    assert_failure
    assert_output --partial "incomplete-backup=1"
    assert_equal "$(_count_calls just)" "0"
}

@test "5.2.3 happy path prints the documented restore evidence and removes the box it owned" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    run _restore_input 4242
    assert_success
    assert_line "restore-rc=0"
    assert_line "restore-ok=1"
    assert_line "blocks=0"
    assert_line "leftover-dirs=0"
    assert_line "dev-gone=1"
    assert_line "backup-removed=1"
    [ ! -e "$(_backup_dir)" ]
}

@test "5.2.3: grep -c prints 0 but cannot read the ghostty config, so blocks is -1, never 0" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    SHIM_GREP_ON='BEGIN worktool managed block' SHIM_GREP_RC=2 SHIM_GREP_OUT='0' \
        run _restore_input 4242
    assert_failure
    assert_line "blocks=-1"
    refute_line "blocks=0"
    assert_output --partial "blocks= is not trustworthy"
}

@test "5.2.3: existing Ghostty blocks survive a successful baseline restore" {
    printf '# BEGIN worktool managed block\n# END worktool managed block\n' \
        >>"$(_ghostty_config)"
    cp "$(_ghostty_config)" "${STATE}/baseline"
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    run _restore_input 4242
    assert_success
    assert_line "blocks=1"
    assert_line "restore-ok=1"
    assert_line "backup-removed=1"
    run cmp "${STATE}/baseline" "$(_ghostty_config)"
    assert_success
}

@test "5.2.3: the owned box surviving removal fails the item" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    FAKE_DBX_RM_REMOVES=0 run _restore_input 4242
    assert_failure
    assert_line "dev-gone=0"
    refute_output --partial "backup-removed=1"
}

@test "5.2.3: a backup that cannot be removed is never reported as removed" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    SHIM_RM_ON='-rf --' SHIM_RM_RC=1 run _restore_input 4242
    assert_failure
    assert_line "dev-gone=1"
    refute_output --partial "backup-removed=1"
    assert_output --partial "removing the backup at"
}

# --- 5.2 as a whole ----------------------------------------------------------

@test "5.2 without a tty says the subjective check cannot be made, and still restores" {
    run "${REALBOX}" --allow-real-box 5.2
    assert_failure
    assert_output --partial "stdin is not a tty"
    # The restore ran anyway: the config is back and the box is gone.
    assert_line "restore-files-ok=1"
    assert_line "restore-ok=0"
    assert_line "dev-gone=1"
    refute_line "backup-removed=1"
    [ -d "$(_backup_dir)" ]
}

# --- 5.2 and the user's own content (GAP A) ----------------------------------
# These run the REAL product out of a copy of the checkout, so the output is
# what it really prints. The scenario is the maintainer's: the state file
# contains a user-config link; bare setup still writes distrobox.conf
# whether or not this run asked it to.

@test "5.2: the apply keeps the user's own content in every managed file (the degraded case below is not vacuous)" {
    local _repo
    _repo="$(_repo_copy)"
    _seed_distrobox_conf
    _seed_shared_state
    FAKE_JUST_BOX_SCRIPT_DIR="${_repo}/script/box" \
        run "${REALBOX}" --allow-real-box 5.2
    # The item still ends at the subjective check, which needs a tty.
    assert_failure
    assert_line "backup-covers=4/4"
    assert_line "user-content after-apply: ghostty=intact config.ghostty=intact distrobox.conf=intact"
    assert_output --partial "stdin is not a tty"
    assert_line "restore-files-ok=1"
    assert_line "restore-ok=0"
    assert_line "blocks=0"
}

@test "5.2: a product whose distrobox isolation path overwrites the whole distrobox.conf is caught after the apply, and the backup puts it back (GAP A)" {
    # Every signal 5.2 used to have stays green: setup exits 0, status is
    # fine, the managed block is in the file, and step 3 reports a clean
    # restore. What says the apply destroyed the maintainer's distrobox
    # configuration is the user-content line - checked BEFORE step 3, or
    # the restore would hide the damage it was meant to undo.
    local _repo
    _repo="$(_repo_copy)"
    _degrade_distrobox_overwrites "${_repo}"
    _seed_distrobox_conf
    _seed_shared_state
    FAKE_JUST_BOX_SCRIPT_DIR="${_repo}/script/box" \
        run "${REALBOX}" --allow-real-box 5.2
    assert_failure
    assert_line "setup-rc=0"
    assert_line "user-content after-apply: ghostty=intact config.ghostty=intact distrobox.conf=LOST"
    assert_output --partial "lost content the user had before this run"
    assert_output --partial "run 5.2.3 to restore it from the backup"
    # The subjective check is never reached; the restore still runs.
    assert_output --partial "re-run 5.2.3 from an interactive shell"
    assert_line "restore-files-ok=1"
    assert_line "restore-ok=0"
    refute_line "backup-removed=1"
    # And the file is back, byte for byte - only possible because the backup
    # set covers distrobox.conf.
    run cat "$(_distrobox_conf)"
    assert_output "$(printf '%s\n' "${DISTROBOX_USER_LINES[@]}")"
}

@test "5.2: existing distrobox blocks survive a successful baseline restore" {
    _seed_distrobox_conf
    printf '# BEGIN worktool managed block\n# END worktool managed block\n' \
        >>"$(_distrobox_conf)"
    cp "$(_distrobox_conf)" "${STATE}/baseline"
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    run _restore_input 4242
    assert_success
    assert_line "blocks=1"
    assert_line "restore-ok=1"
    assert_line "backup-removed=1"
    run cmp "${STATE}/baseline" "$(_distrobox_conf)"
    assert_success
}

# --- 5.3 the pre-existing-box refusal ----------------------------------------

@test "5.3: documented refusal and restore lines follow the actual output order" {
    bats_require_minimum_version 1.5.0
    local _actual _documented _keys
    _keys='^(52-rc|restore-rc|restore-ok|blocks|leftover-dirs|dev-untouched|backup-removed|still-there)='
    run --separate-stderr "${REALBOX}" --allow-real-box 5.3
    assert_success
    assert_line "dev-untouched=1"
    [[ "${stderr:-}" == *'[INFO] this run never created a box; leaving every box alone'* ]]
    _actual="$(printf '%s\n' "${output}" | grep -E "${_keys}" \
        | sed 's/^blocks=.*/blocks=<執行前的區塊總數>/')"
    _documented="$(sed -n '/^  - \[ \] 5\.3 先建/,/^  PR #228/p' \
        "${REPO_ROOT}/doc/acceptance.md" | sed -n '/預期看到資訊/p' | grep -o "\`[^\`]*\`" \
        | sed 's/`//g' | grep -E "${_keys}")"
    assert_equal "${_documented}" "${_actual}"
}

@test "5.3 happy path proves 5.1 and 5.2 step 2 refuse, and the box survives" {
    run "${REALBOX}" --allow-real-box 5.3
    assert_success
    assert_line "preexisting=dev"
    assert_line --partial "a distrobox named 'dev' already exists -- refusing"
    assert_line "51-rc=1"
    assert_line "ghostty=regular"
    assert_line "worktool=absent-dir"
    assert_line "revalidate=1"
    assert_line "52-rc=1"
    assert_line "restore-rc=0"
    assert_line "restore-ok=1"
    assert_line "blocks=0"
    assert_line "leftover-dirs=0"
    assert_line "dev-untouched=1"
    assert_line "backup-removed=1"
    assert_line "still-there=dev"
    assert_line "decoy-cleanup-rc=0"
    # Nothing in the whole run printed the 5.1 / 5.2 "we own a box" markers.
    refute_line "preexisting-dev=0"
    refute_line "dev-gone=1"
}

@test "5.3: distrobox create prints plausible output but exits 1 (plausible output, non-zero exit)" {
    FAKE_DBX_CREATE_RC=1 FAKE_DBX_CREATE_OUT='Creating the container dev...' \
        run "${REALBOX}" --allow-real-box 5.3
    assert_failure
    assert_output --partial "distrobox create --name dev failed"
    refute_output --partial "preexisting=dev"
}

@test "5.3: create returns 0 but the box is not listed" {
    FAKE_DBX_CREATE_REGISTERS=0 run "${REALBOX}" --allow-real-box 5.3
    assert_failure
    assert_output --partial "no box named 'dev' after create"
    refute_output --partial "preexisting=dev"
}

@test "5.3: a box named dev already exists, so no decoy is created and none is deleted" {
    _seed_box dev
    run "${REALBOX}" --allow-real-box 5.3
    assert_failure
    assert_output --partial "5.3 creates the decoy box itself"
    assert_equal "$(_count_calls just)" "0"
    run cat "${STATE}/boxes"
    assert_line "dev"
}

@test "5.3: the final listing prints the dev row but exits 1, so 'still there' is not concluded" {
    # Learn how many `distrobox list` calls a green 5.3 makes, then break the
    # one that decides the box survived (the last call is the decoy cleanup).
    _realbox_quiet 5.3
    local _n
    _n="$(_count_list_calls)"
    [ "${_n}" -ge 2 ]
    _reset_log
    : >"${STATE}/boxes"
    FAKE_DBX_LIST_FAIL_FROM="$((_n - 1))" run "${REALBOX}" --allow-real-box 5.3
    assert_failure
    assert_output --partial "must not be concluded from a list nobody could read"
    refute_output --partial "still-there=dev"
}

@test "5.2: backup and restore cover both Ghostty files and distrobox config" {
    mkdir -p "${HOME}/.config/distrobox"
    printf 'font-size = 17\n' >"${HOME}/.config/ghostty/config.ghostty"
    printf 'container_manager=docker\n' >"${HOME}/.config/distrobox/distrobox.conf"
    run "${REALBOX}" --allow-real-box 5.2.1
    assert_success
    assert_line "backup-covers=4/4"
    assert_line "ghostty-modern=regular"
    assert_line "distrobox-conf=regular"
    printf 'changed\n' >"${HOME}/.config/ghostty/config.ghostty"
    printf 'changed\n' >"${HOME}/.config/distrobox/distrobox.conf"
    run _restore_input 4242
    assert_success
    run cat "${HOME}/.config/ghostty/config.ghostty"
    assert_output 'font-size = 17'
    run cat "${HOME}/.config/distrobox/distrobox.conf"
    assert_output 'container_manager=docker'
}

@test "5.2: new-window instructions check direct fish entry without a tmux session" {
    run "${REALBOX}" --allow-real-box 5.2
    assert_failure
    assert_output --partial "echo \$fish_pid"
    assert_output --partial "Open a NEW ghostty window"
    refute_output --partial "tmux display"
    assert_line "restore-files-ok=1"
    assert_line "restore-ok=0"
}

@test "5.2.2: acceptance uses an owned box HOME inside its backup" {
    _realbox_quiet 5.2.1
    run "${REALBOX}" --allow-real-box 5.2.2
    assert_success
    run cat "${STATE}/calls.log"
    assert_line "just box assemble --home $(_backup_dir)/box-home"
}

@test "single source: acceptance backup paths equal every file real setup writes" {
    local _home="${BATS_TEST_TMPDIR}/product-home" _actual _expected _name
    local _just
    _just="$(cat "${STATE}/real/just")"
    mkdir -p "${_home}"
    run env HOME="${_home}" XDG_CONFIG_HOME="${_home}/.config" \
        PATH="/usr/local/bin:/usr/bin:/bin" "${_just}" box setup --terminal ghostty
    assert_success
    mkdir -p "${_home}/.config/ghostty"
    : >"${_home}/.config/ghostty/config.ghostty"
    run env HOME="${_home}" XDG_CONFIG_HOME="${_home}/.config" \
        PATH="/usr/local/bin:/usr/bin:/bin" "${_just}" box setup --terminal ghostty
    assert_success
    _actual="$(find "${_home}" -type f | sort)"
    source "${REPO_ROOT}/script/verify/config_backup_paths.sh"
    CFGBK_C="${_home}/.config"
    _expected="$(for _name in "${CFGBK_NAMES[@]}"; do cfgbk_file_of "${_name}"; done | sort)"
    assert_equal "${_expected}" "${_actual}"
}

# Inject measurements at the public clock/tool seam; never source bench.sh.
_install_bench_samples() {
    local _bin="${BATS_TEST_TMPDIR}/bench-bin" _sample
    mkdir -p "${_bin}"
    export BENCH_SAMPLE_DIR="${_bin}"
    printf '0\n' >"${_bin}/clock"
    printf '0\n' >"${_bin}/calls"
    : >"${_bin}/samples"
    for _sample in "$@"; do
        awk -v n="${_sample}" 'BEGIN {printf "%.0f\n", n*1000}' >>"${_bin}/samples"
    done
    cat >"${_bin}/clock.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat "${BENCH_SAMPLE_DIR}/clock"
EOF
    cat >"${_bin}/distrobox" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
read -r _clock <"${BENCH_SAMPLE_DIR}/clock"
read -r _calls <"${BENCH_SAMPLE_DIR}/calls"
mapfile -t _samples <"${BENCH_SAMPLE_DIR}/samples"
_us="${_samples[_calls % 3]}"
printf '%s\n' "$((_clock + _us))" >"${BENCH_SAMPLE_DIR}/clock"
printf '%s\n' "$((_calls + 1))" >"${BENCH_SAMPLE_DIR}/calls"
if [[ "$*" == *bench-inbox* ]]; then printf '%s\n' "${_us}"; fi
EOF
    chmod +x "${_bin}/clock.sh" "${_bin}/distrobox"
}

_assert_product_bench_sample() {
    local _line="$1" _min _median _max _kind=INFO _limit=999999
    local _metric_re='^(enter|shell|inbox): min=([0-9]+(\.[0-9]+)?) median=([0-9]+(\.[0-9]+)?) max=([0-9]+(\.[0-9]+)?) ms$'
    local _notice_re='^\[(INFO|ERROR)\] shell median ([0-9]+(\.[0-9]+)?) ms (within|exceeds) --max-ms ([0-9]+)$'
    if [[ "${_line}" =~ ${_metric_re} ]]; then
        _min="${BASH_REMATCH[2]}" _median="${BASH_REMATCH[4]}" _max="${BASH_REMATCH[6]}"
    elif [[ "${_line}" =~ ${_notice_re} ]]; then
        _kind="${BASH_REMATCH[1]}" _median="${BASH_REMATCH[2]}" _limit="${BASH_REMATCH[5]}"
        _min="${_median}" _max="${_median}"
    else
        fail "unrecognised bench sample: ${_line}"
        return 1
    fi
    _install_bench_samples "${_min}" "${_median}" "${_max}"
    local _bin="${BENCH_SAMPLE_DIR}"
    run env PATH="${_bin}:/usr/local/bin:/usr/bin:/bin" BENCH_CLOCK="${_bin}/clock.sh" \
        BENCH_PSI_FILE="${_bin}/absent-psi" "${REPO_ROOT}/script/box/bench.sh" \
        --runs 3 --warmup 0 --max-ms "${_limit}"
    if [[ "${_kind}" == INFO ]]; then
        assert_success || return 1
    else
        assert_failure 1 || return 1
    fi
    assert_line "${_line}"
}

@test "single source: bench guard catches a CLI that prints failure but exits zero" {
    local _repo
    _repo="$(_repo_copy)"
    cat >"${_repo}/script/box/bench.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '[ERROR] shell median 301.0 ms exceeds --max-ms 300'
exit 0
EOF
    REPO_ROOT="${_repo}" run _assert_product_bench_sample \
        '[ERROR] shell median 301.0 ms exceeds --max-ms 300'
    assert_failure
}

@test "single source: bench fixture and documented samples match real product formatting" {
    local _fixture _line
    run "${STUBS}/just" box bench
    assert_success
    _fixture="${output}"
    while IFS= read -r _line; do _assert_product_bench_sample "${_line}"; done <<<"${_fixture}"
    while IFS= read -r _line; do _assert_product_bench_sample "${_line}"; done < <(
        sed -n -e 's/^ *# bench\(-gate\)\?: //p' \
            -e 's/^ *\(\(enter\|shell\|inbox\): min=.*\)$/\1/p' \
            -e 's/^ *\(\[INFO\] shell median .*\)$/\1/p' "${REPO_ROOT}/doc/acceptance.md"
    )
}

@test "single source: realbox product output stubs agree with real dry-runs and status" {
    local _just _verb _real _line _args=()
    _just="$(cat "${STATE}/real/just")"
    for _verb in assemble setup status; do
        _args=()
        [[ "${_verb}" == status ]] || _args=(--dry-run)
        run "${_just}" box "${_verb}" "${_args[@]}"
        assert_success
        _real="${output}"
        run "${STUBS}/just" box "${_verb}" "${_args[@]}"
        assert_success
        local _fixture="${output}"
        while IFS= read -r _line; do
            printf '# product stub line: %s\n' "${_line}" >&3
            run grep -Fx "${_line}" <<<"${_real}"
            assert_success
        done <<<"${_fixture}"
    done
}

@test "5.2.3: custom box HOME socket state is checked and removed" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    local _home
    _home="$(_backup_dir)/box-home"
    mkdir -p "${_home}/.cache/tmux/tmux-1000"
    node -e 'require("net").createServer().listen(process.argv[1], () => process.exit(0))' \
        "${_home}/.cache/tmux/tmux-1000/default"
    [ -S "${_home}/.cache/tmux/tmux-1000/default" ]
    run _restore_input 4242
    assert_success
    assert_line "box-state before-cleanup: home=1 tmux=1"
    assert_line "box-state after-cleanup: home=0 tmux=0"
    [ ! -e "${_home}" ]
}

@test "5.2.3: unrelated host file and socket survive while owned HOME is removed" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    local _home="${HOME}/dev-box" _owned
    _owned="$(_backup_dir)/box-home"
    mkdir -p "${_home}" "${_owned}/.cache/tmux"
    printf 'unrelated host data\n' >"${_home}/notes"
    node -e 'require("net").createServer().listen(process.argv[1], () => process.exit(0))' \
        "${_home}/host-socket"
    printf 'run state\n' >"${_owned}/owned"
    node -e 'require("net").createServer().listen(process.argv[1], () => process.exit(0))' \
        "${_owned}/.cache/tmux/default"
    bats_require_minimum_version 1.5.0
    run --separate-stderr "${REALBOX}" --allow-real-box 5.2.3
    assert_failure 1
    assert_line "host-state before-cleanup: new=3"
    assert_line "host-state kept-unknown=3"
    assert_line "host-state after-cleanup: new=3"
    [[ "${stderr}" == *"${_home}/notes"* ]]
    [[ "${stderr}" == *"${_home}/host-socket"* ]]
    assert_equal "$(cat "${_home}/notes")" 'unrelated host data'
    [ -S "${_home}/host-socket" ]
    [ ! -e "${_owned}" ]
    [ -d "$(_backup_dir)" ]
}

@test "5.2.3: retry after failed owned HOME cleanup removes owned leftovers before deleting the backup" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    local _home _backup
    _home="$(_backup_dir)/box-home"
    _backup="$(_backup_dir)"
    mkdir -p "${_home}"
    printf 'owned state\n' >"${_home}/leftover"
    SHIM_RM_ON="-rf -- ${_home}" SHIM_RM_RC=1 \
        run _restore_input 4242
    assert_failure 1
    assert_line "box-state after-cleanup: home=1 tmux=0"
    assert_output --partial 'fix the errors above and re-run 5.2.3'
    refute_output --partial 'backup-removed=1'
    [ -d "${_backup}" ]
    [ -f "${_home}/leftover" ]
    [ ! -s "${STATE}/boxes" ]

    run _restore_input 4242
    assert_success
    refute_output --partial 'dev-untouched=1'
    refute_output --partial 'host-state untouched:'
    assert_line "host-state before-cleanup: new=0"
    assert_line "host-state after-cleanup: new=0"
    assert_line 'backup-removed=1'
    [ ! -e "${_home}" ]
    [ ! -e "${_backup}" ]
}

@test "5.2.3: host already has dev-box and its user data survives cleanup" {
    local _home="${HOME}/dev-box"
    mkdir -p "${_home}/.cache/tmux/tmux-1000"
    printf 'user data\n' >"${_home}/notes"
    chmod 600 "${_home}/notes"
    ln -s notes "${_home}/notes-link"
    node -e 'require("net").createServer().listen(process.argv[1], () => process.exit(0))' \
        "${_home}/.cache/tmux/tmux-1000/user"
    run "${REALBOX}" --allow-real-box 5.2.1
    assert_success
    assert_line "host-state baseline: present=1"
    _realbox_quiet 5.2.2
    printf 'updated user data\n' >"${_home}/notes"
    node -e 'require("net").createServer().listen(process.argv[1], () => process.exit(0))' \
        "${_home}/.cache/tmux/tmux-1000/default"
    run _restore_input 4242
    assert_failure 1
    assert_line "host-state kept-unknown=1"
    assert_line "host-state before-cleanup: new=1"
    assert_line "host-state after-cleanup: new=1"
    assert_equal "$(cat "${_home}/notes")" "updated user data"
    assert_equal "$(stat -c %a "${_home}/notes")" "600"
    assert_equal "$(readlink "${_home}/notes-link")" "notes"
    [ -S "${_home}/.cache/tmux/tmux-1000/user" ]
    [ -S "${_home}/.cache/tmux/tmux-1000/default" ]
}

@test "5.3: decoy box state uses an isolated HOME and is removed" {
    cp "${STUBS}/distrobox" "${STATE}/distrobox"
    export VERIFY_DBX="${STATE}/distrobox"
    cat >"${STUBS}/distrobox" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == create ]]; then
    home="${HOME}/dev-box"
    previous=""
    for arg in "$@"; do
        if [[ "${previous}" == --home ]]; then home="${arg}"; fi
        previous="${arg}"
    done
    printf '%s\n' "${home}" >"${FAKE_STATE_DIR}/decoy-home"
    mkdir -p "${home}/.cache/tmux"
    node -e 'require("net").createServer().listen(process.argv[1], () => process.exit(0))' \
        "${home}/.cache/tmux/default"
fi
exec "${VERIFY_DBX}" "$@"
STUB
    run "${REALBOX}" --allow-real-box 5.3
    assert_success
    local _home
    IFS= read -r _home <"${STATE}/decoy-home"
    [ "${_home}" != "${HOME}/dev-box" ]
    [ ! -e "${_home}" ]
    [ ! -e "${HOME}/dev-box" ]
    assert_line "box-state before-cleanup: home=1 tmux=1"
    assert_line "box-state after-cleanup: home=0 tmux=0"
}

@test "5.2.3: host state added after backup is preserved when this run never created a box" {
    _realbox_quiet 5.2.1
    local _home="${HOME}/dev-box"
    _seed_box dev
    mkdir -p "${_home}/.cache/tmux"
    printf 'user config\n' >"${_home}/.profile"
    printf 'user history\n' >"${_home}/.history"
    ln -s .profile "${_home}/profile-link"
    node -e 'require("net").createServer().listen(process.argv[1], () => process.exit(0))' \
        "${_home}/.cache/tmux/user"
    run "${REALBOX}" --allow-real-box 5.2.2
    assert_failure 1
    assert_output --partial "already exists -- refusing"
    [ ! -e "$(_backup_dir)/created-box" ]
    run _restore_input 4242
    assert_success
    assert_line 'dev-untouched=1'
    assert_line 'host-state untouched: new=7'
    refute_output --partial 'host-state after-cleanup:'
    assert_equal "$(cat "${_home}/.profile")" 'user config'
    assert_equal "$(cat "${_home}/.history")" 'user history'
    assert_equal "$(readlink "${_home}/profile-link")" '.profile'
    [ -S "${_home}/.cache/tmux/user" ]
    assert_equal "$(cat "${STATE}/boxes")" dev
}

@test "5.1: assemble and cleanup retain the same user distrobox config while isolating state" {
    local _config="${HOME}/custom-config" _verb
    local _conf="${_config}/distrobox/distrobox.conf"
    mkdir -p "${_config}/distrobox" "${_config}/worktool"
    printf '%s\n' "${DISTROBOX_USER_LINES[@]}" \
        '# BEGIN worktool managed block' 'unset TMUX TMUX_PANE' \
        '# END worktool managed block' >"${_conf}"
    printf 'home=/original\nhome.source=user\n' >"${_config}/worktool/config"
    cp "${_config}/worktool/config" "${STATE}/baseline-state"
    cp "${_conf}" "${STATE}/baseline-distrobox"
    run env XDG_CONFIG_HOME="${_config}" FAKE_DBX_RECORD_CONFIG=1 \
        FAKE_JUST_ASSEMBLE_WRITES_STATE=1 "${REALBOX}" --allow-real-box 5.1
    assert_success
    assert_line 'cleanup-rc=0'
    for _verb in assemble list rm; do
        run cmp "${STATE}/baseline-distrobox" "${STATE}/distrobox-config-${_verb}"
        assert_success
    done
    run cat "${STATE}/distrobox-managers"
    assert_line 'assemble manager=docker'
    assert_line 'list manager=docker'
    assert_line 'rm manager=docker'
    refute_output --partial 'manager=podman'
    run cmp "${STATE}/baseline-state" "${_config}/worktool/config"
    assert_success
    run cmp "${STATE}/baseline-distrobox" "${_conf}"
    assert_success
    [ ! -s "${STATE}/boxes" ]
}

@test "5.1: assemble list and rm see the same container config while isolating state" {
    local _config="${HOME}/custom-config" _verb _file
    mkdir -p "${_config}/containers/containers.conf.d" "${_config}/worktool"
    printf '[storage]\ngraphroot = "/custom/store"\n' >"${_config}/containers/storage.conf"
    printf '[engine]\nactive_service = "custom"\n' >"${_config}/containers/containers.conf"
    printf '[engine.service_destinations.custom]\nuri = "ssh://custom/run/podman.sock"\n' \
        >"${_config}/containers/containers.conf.d/connection.conf"
    printf 'home=/original\nhome.source=user\n' >"${_config}/worktool/config"
    cp "${_config}/worktool/config" "${STATE}/baseline-state"
    run env XDG_CONFIG_HOME="${_config}" FAKE_DBX_RECORD_CONTAINER_CONFIG=1 \
        FAKE_JUST_ASSEMBLE_WRITES_STATE=1 "${REALBOX}" --allow-real-box 5.1
    assert_success
    assert_line 'cleanup-rc=0'
    for _verb in assemble list rm; do
        for _file in storage.conf containers.conf containers.conf.d/connection.conf; do
            run cmp "${_config}/containers/${_file}" "${STATE}/container-config-${_verb}-${_file##*/}"
            assert_success
        done
    done
    run cmp "${STATE}/baseline-state" "${_config}/worktool/config"
    assert_success
    [ ! -s "${STATE}/boxes" ]
}

@test "5.1: assemble state writes leave existing real state byte-identical" {
    export XDG_CONFIG_HOME="${HOME}/custom-config"
    local _state="${XDG_CONFIG_HOME}/worktool/config" _baseline="${STATE}/baseline"
    mkdir -p "${XDG_CONFIG_HOME}/worktool"
    printf '# user state\r\nhome=/original\nhome.source=user\nlink=keep\n\n' >"${_state}"
    cp "${_state}" "${_baseline}"
    FAKE_JUST_ASSEMBLE_WRITES_STATE=1 run "${REALBOX}" --allow-real-box 5.1
    assert_success
    [ -s "${STATE}/assemble-home" ]
    run cmp "${_baseline}" "${_state}"
    assert_success
    [ "$(cat "${STATE}/assemble-config-dir")" != "${XDG_CONFIG_HOME}" ]
}

@test "5.1: assemble state writes leave absent real state absent" {
    local _state="${HOME}/.config/worktool/config"
    [ ! -e "${_state}" ]
    FAKE_JUST_ASSEMBLE_WRITES_STATE=1 run "${REALBOX}" --allow-real-box 5.1
    assert_success
    [ -s "${STATE}/assemble-home" ]
    [ ! -e "${_state}" ]
    [ ! -d "${HOME}/.config/worktool" ]
}

@test "5.1: assemble failure leaves real state byte-identical" {
    local _state="${HOME}/.config/worktool/config" _baseline="${STATE}/baseline"
    mkdir -p "${HOME}/.config/worktool"
    printf 'home=/original\nhome.source=user\nlink=keep\n\n' >"${_state}"
    cp "${_state}" "${_baseline}"
    FAKE_JUST_ASSEMBLE_WRITES_STATE=1 FAKE_JUST_ASSEMBLE_RC=1 \
        run "${REALBOX}" --allow-real-box 5.1
    assert_failure 1
    assert_output --partial 'just box assemble failed'
    assert_line 'cleanup-rc=0'
    [ -s "${STATE}/assemble-home" ]
    run cmp "${_baseline}" "${_state}"
    assert_success
}

@test "5.3: existing managed blocks match the pre-run baseline" {
    local _file _files=("$(_ghostty_config)" "${HOME}/.config/ghostty/config.ghostty" "$(_distrobox_conf)") _i=0
    mkdir -p "${HOME}/.config/distrobox"
    for _file in "${_files[@]}"; do
        printf '# BEGIN worktool managed block\nuser baseline\n# END worktool managed block\n' >>"${_file}"
        cp "${_file}" "${STATE}/baseline-${_i}"
        _i=$((_i + 1))
    done
    run "${REALBOX}" --allow-real-box 5.3
    assert_success
    assert_line 'restore-ok=1'
    assert_line 'blocks=3'
    assert_line 'backup-removed=1'
    _i=0
    for _file in "${_files[@]}"; do
        run cmp "${STATE}/baseline-${_i}" "${_file}"
        assert_success
        _i=$((_i + 1))
    done
}

@test "5.2.3: restored bytes differing from baseline fail even with zero blocks" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    VERIFY_RESTORE_SOURCE="$(_backup_dir)/ghostty.config"
    export VERIFY_RESTORE_SOURCE
    VERIFY_CP="$(cat "${STATE}/real/cp")"
    export VERIFY_CP
    cat >"${STUBS}/cp" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
"${VERIFY_CP}" "$@"
if [[ "${3:-}" == "${VERIFY_RESTORE_SOURCE}" ]]; then
    printf 'corrupted user content\n' >"${4}"
fi
STUB
    run _restore_input 4242
    assert_failure 1
    assert_line 'restore-ok=0'
    assert_line 'blocks=0'
    assert_output --partial 'restored content checksum mismatch'
    refute_line 'backup-removed=1'
    [ -d "$(_backup_dir)" ]
}

@test "#471: restore cannot complete before reload evidence" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    run "${REALBOX}" --allow-real-box 5.2.3
    assert_failure 1
    assert_output --partial 'Reload the RESTORED Ghostty config'
    assert_output --partial 'Ctrl+Shift+,'
    refute_line 'restore-ok=1'
    assert_line 'restore-window-ok=0'
    refute_line 'backup-removed=1'
    [ -d "$(_backup_dir)" ]
}

_restore_input() {
    export REALBOX
    cat >"${STUBS}/ps" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    '-e -o pid=,comm=') printf '1 init\n' ;;
    '-p 4242 -o comm=') printf 'fish\n' ;;
    '-p 4242 -o ppid=,args=') printf '%s\n' "${FAKE_RESTORE_PARENT:-900 /usr/bin/fish}" ;;
    '-p 800 -o ppid=,args=') printf "900 /bin/sh -c '/repo/script/box/enter.sh' --box dev\n" ;;
    '-p 900 -o ppid=,args=') printf '1 /usr/bin/ghostty\n' ;;
    *) exit 1 ;;
esac
STUB
    cat >"${STUBS}/readlink" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == /proc/4242/ns/mnt ]]; then
    exec "$(cat "${FAKE_STATE_DIR}/real/readlink")" /proc/self/ns/mnt
fi
exec "$(cat "${FAKE_STATE_DIR}/real/readlink")" "$@"
STUB
    chmod +x "${STUBS}/ps" "${STUBS}/readlink"
    cat >"${STATE}/restore-run" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
rc=0
"${REALBOX}" --allow-real-box 5.2.3 || rc=$?
printf '%s\n' "${rc}" >"${FAKE_STATE_DIR}/restore-rc"
STUB
    printf '%s\n' "$1" | script -q -c "bash '${STATE}/restore-run'" /dev/null | tr -d '\r'
    return "$(cat "${STATE}/restore-rc")"
}

@test "#471: a clean post-restore Ghostty window completes restore" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    run _restore_input 4242
    assert_success
    assert_output --partial 'restore-window-evidence: pid=4242 comm=fish'
    assert_line 'restore-window-ok=1'
    assert_line 'backup-removed=1'
    [ ! -e "$(_backup_dir)" ]
}

@test "#471: a post-restore window still running enter.sh fails" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    FAKE_RESTORE_PARENT='800 /usr/bin/fish' run _restore_input 4242
    assert_failure 1
    assert_output --partial 'restored window still runs script/box/enter.sh'
    assert_line 'restore-window-ok=0'
    refute_line 'backup-removed=1'
    [ -d "$(_backup_dir)" ]
}
