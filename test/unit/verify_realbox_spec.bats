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
    for _t in just "${REALBOX_SHIMMED_TOOLS[@]}"; do
        command -v -- "${_t}" >"${STATE}/real/${_t}"
    done
    for _t in "${REALBOX_FAKED_TOOLS[@]}"; do
        install -m 0755 "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${STUBS}/${_t}"
    done
    for _t in "${REALBOX_SHIMMED_TOOLS[@]}"; do
        install -m 0755 "${BATS_TEST_DIRNAME}/fixture/realbox_shim.sh" "${STUBS}/${_t}"
    done

    printf 'font-size = 12\n' >"${BATS_TEST_TMPDIR}/home/.config/ghostty/config"

    export FAKE_STATE_DIR="${STATE}"
    export HOME="${BATS_TEST_TMPDIR}/home"
    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    unset XDG_CONFIG_HOME
    PATH="${STUBS}:${PATH}"
    export PATH
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
    assert_failure
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
    assert_output --partial "shell median 400.5 ms is not below the --max-ms 300"
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
    run "${REALBOX}" --allow-real-box 5.2.3
    assert_success
    assert_output --partial "no-backup=1"
    assert_equal "$(_count_calls just)" "0"
}

@test "5.2.3: a backup dir with no published manifest is reported, not restored" {
    mkdir -p "$(_backup_dir)"
    run "${REALBOX}" --allow-real-box 5.2.3
    assert_failure
    assert_output --partial "incomplete-backup=1"
    assert_equal "$(_count_calls just)" "0"
}

@test "5.2.3 happy path prints the six documented lines and removes the box it owned" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    run "${REALBOX}" --allow-real-box 5.2.3
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
        run "${REALBOX}" --allow-real-box 5.2.3
    assert_failure
    assert_line "blocks=-1"
    refute_line "blocks=0"
    assert_output --partial "blocks= is not trustworthy"
}

@test "5.2.3: a managed block still in the config fails the item" {
    printf '# BEGIN worktool managed block\n# END worktool managed block\n' \
        >>"$(_ghostty_config)"
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    run "${REALBOX}" --allow-real-box 5.2.3
    assert_failure
    assert_line "blocks=1"
    assert_output --partial "managed block still present"
}

@test "5.2.3: the owned box surviving removal fails the item" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    FAKE_DBX_RM_REMOVES=0 run "${REALBOX}" --allow-real-box 5.2.3
    assert_failure
    assert_line "dev-gone=0"
    refute_output --partial "backup-removed=1"
}

@test "5.2.3: a backup that cannot be removed is never reported as removed" {
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    SHIM_RM_ON='-rf --' SHIM_RM_RC=1 run "${REALBOX}" --allow-real-box 5.2.3
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
    assert_line "restore-ok=1"
    assert_line "dev-gone=1"
    assert_line "backup-removed=1"
    [ ! -e "$(_backup_dir)" ]
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
    assert_line "restore-ok=1"
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
    refute_output --partial "stdin is not a tty"
    assert_line "restore-ok=1"
    assert_line "backup-removed=1"
    # And the file is back, byte for byte - only possible because the backup
    # set covers distrobox.conf.
    run cat "$(_distrobox_conf)"
    assert_output "$(printf '%s\n' "${DISTROBOX_USER_LINES[@]}")"
}

@test "5.2: a managed block left in distrobox.conf fails the restore, exactly as one left in the ghostty config does" {
    # blocks= counts every user-owned managed file: a restore that put the
    # ghostty config back and forgot distrobox.conf used to print blocks=0.
    _seed_distrobox_conf
    printf '# BEGIN worktool managed block\n# END worktool managed block\n' \
        >>"$(_distrobox_conf)"
    _realbox_quiet 5.2.1
    _realbox_quiet 5.2.2
    run "${REALBOX}" --allow-real-box 5.2.3
    assert_failure
    assert_line "blocks=1"
    assert_output --partial "managed block still present in $(_distrobox_conf)"
}

# --- 5.3 the pre-existing-box refusal ----------------------------------------

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
    assert_line --partial "dev-untouched=1"
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
    run "${REALBOX}" --allow-real-box 5.2.3
    assert_success
    run cat "${HOME}/.config/ghostty/config.ghostty"
    assert_output 'font-size = 17'
    run cat "${HOME}/.config/distrobox/distrobox.conf"
    assert_output 'container_manager=docker'
}

@test "5.2: new-window instructions check direct fish entry without a tmux session" {
    run "${REALBOX}" --allow-real-box 5.2
    assert_failure
    assert_output --partial "Expected: container marker (/run/.containerenv or /.dockerenv), then fish"
    refute_output --partial "tmux display"
    assert_line "restore-ok=1"
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

_assert_product_bench_sample() {
    local _line="$1" _metric _min _median _max _kind _limit
    local _metric_re='^(enter|shell|inbox): min=([0-9]+(\.[0-9]+)?) median=([0-9]+(\.[0-9]+)?) max=([0-9]+(\.[0-9]+)?) ms$'
    local _notice_re='^\[(INFO|ERROR)\] shell median ([0-9]+(\.[0-9]+)?) ms (within|exceeds) --max-ms ([0-9]+)$'
    if [[ "${_line}" =~ ${_metric_re} ]]; then
        _metric="${BASH_REMATCH[1]}"
        _min="${BASH_REMATCH[2]}" _median="${BASH_REMATCH[4]}" _max="${BASH_REMATCH[6]}"
        run bash -c 'source "$1"; _print_text "$2" "$3" "$4" "$5"' _ \
            "${REPO_ROOT}/script/box/bench.sh" "${_metric}" \
            "$(awk -v n="${_min}" 'BEGIN {printf "%.0f", n*1000}')" \
            "$(awk -v n="${_median}" 'BEGIN {printf "%.0f", n*1000}')" \
            "$(awk -v n="${_max}" 'BEGIN {printf "%.0f", n*1000}')"
        assert_success
    elif [[ "${_line}" =~ ${_notice_re} ]]; then
        _kind="${BASH_REMATCH[1]}" _median="${BASH_REMATCH[2]}" _limit="${BASH_REMATCH[5]}"
        run bash -c 'source "$1"; OPT_MAX_MS="$2"; _check_threshold "$3"' _ \
            "${REPO_ROOT}/script/box/bench.sh" "${_limit}" \
            "$(awk -v n="${_median}" 'BEGIN {printf "%.0f", n*1000}')"
        if [[ "${_kind}" == INFO ]]; then assert_success; else assert_failure 1; fi
    else
        fail "unrecognised bench sample: ${_line}"
    fi
    assert_equal "${output}" "${_line}"
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
