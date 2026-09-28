#!/usr/bin/env bats
# test/unit/verify_setup_spec.bats - script/verify/setup.sh (M3 acceptance
# items 3.1-3.6, moved out of doc/acceptance.md)
#
# WHAT THIS PROVES
#   The one property the move exists to buy: A FAILURE CANNOT READ AS A
#   PASS. For every item, the first stage of every pipeline and every
#   external tool the item leans on is replaced with a stub that MISBEHAVES,
#   and the script must exit non-zero. At least one stub per item still
#   prints entirely plausible output and only fails in its EXIT STATUS -
#   that is the exact bug the document's hand-pasted blocks could hide:
#
#     just | sed      -> the pipeline reports sed's 0, the failed just is lost
#     find | wc -l    -> a broken find still answers "0 files", i.e. "clean"
#     grep -c PAT F   -> exit 2 ("cannot read F") prints 0, same as "no match"
#     $(cmd)          -> a plausible string with a non-zero status behind it
#
#   It also proves the environment gate: when ghostty, distrobox or just is
#   not here, the affected item SAYS SO and exits non-zero. Nothing is
#   skipped silently.
#
#   And the group-`realbox` protocol: a real-machine item may not run
#   without the explicit opt-in, may not run when a box named `dev` already
#   exists, and a box this run claimed is removed by the cleanup that the
#   EXIT INT TERM HUP traps share.
#
# HOW
#   Every case runs against a throwaway TMPDIR, and every item the script
#   runs builds its own throwaway HOME under it, so no real configuration
#   is read or written and no box, daemon or package is involved. The image
#   ships no ghostty, so a trivial one is stubbed in for the whole spec;
#   distrobox and just are the real ones the image carries.
#
#   The stubs delegate to the REAL tool (resolved before the stub dir is
#   put on PATH) and then break exactly one thing, so each case pins one
#   guard instead of breaking the run wholesale.
#
#   The first case is the control: with everything behaving, all six items
#   pass. Without it the failure cases below would also be satisfied by a
#   script that can never pass at all.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    VERIFY="${REPO_ROOT}/script/verify/setup.sh"
    STUB="${BATS_TEST_TMPDIR}/stub"
    LINKS="${BATS_TEST_TMPDIR}/links"
    mkdir -p "${STUB}" "${LINKS}"

    # Keep every mktemp -d the script makes inside the case's own tmpdir.
    TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"
    export TMPDIR

    # The real tools, resolved BEFORE the stub directory shadows them, so a
    # stub can still delegate to the genuine article.
    REAL_GREP="$(command -v grep)"
    REAL_SED="$(command -v sed)"
    REAL_FIND="$(command -v find)"
    REAL_MKTEMP="$(command -v mktemp)"
    REAL_JUST="$(command -v just)"

    # No test image ships ghostty; setup.sh only ever runs `command -v` on
    # it, so an executable that does nothing is a faithful stand-in.
    _stub ghostty '#!/bin/sh' 'exit 0'

    # A PATH that holds just and ghostty but NOT distrobox (which the image
    # keeps in /usr/local/bin) - used by the environment-gate cases.
    ln -s "${REAL_JUST}" "${LINKS}/just"
    ln -s "${STUB}/ghostty" "${LINKS}/ghostty"
    NO_DISTROBOX_PATH="${LINKS}:/usr/bin:/bin"

    export PATH="${STUB}:${PATH}"
}

# Write $STUB/$1 from the remaining arguments, one line each, executable.
_stub() {
    local _name="$1"
    shift
    printf '%s\n' "$@" >"${STUB}/${_name}"
    chmod +x "${STUB}/${_name}"
}

# --- The stubs ----------------------------------------------------------------

# A `just` that prints exactly the lines doc/acceptance.md shows and then
# exits $1. Plausible to the eye, wrong in the only place that counts.
_stub_just_plausible() {
    _stub just \
        '#!/bin/sh' \
        'printf "./script/box/setup.sh \"\$@\"\n" >&2' \
        'printf "[INFO] auto-enter: yes (default)\n" >&2' \
        'printf "[INFO] terminal: ghostty (default)\n" >&2' \
        'printf "[INFO] tmux: inside (default)\n" >&2' \
        'printf "[INFO] box: dev (default)\n" >&2' \
        'printf "config: /throwaway/.config/worktool/config\n"' \
        'printf "distrobox: /usr/local/bin/distrobox (recorded in a managed block: runnable)\n"' \
        "exit $1"
}

# A `sed` that transforms its input exactly as the real one does and only
# then exits 1: the normalising stage of every printed block.
_stub_sed_output_then_fail() {
    _stub sed \
        '#!/bin/sh' \
        "${REAL_SED} \"\$@\"" \
        'exit 1'
}

# A `find` that answers with a plausible file list and exits 1. Any
# `-type f` call (the file counter) is broken; everything else is real.
_stub_find_list_then_fail() {
    cat >"${STUB}/find" <<EOF
#!/bin/sh
case " \$* " in
  *" -type f "*)
    printf "%s/.config/worktool/config\n" "\$1"
    exit 1
    ;;
esac
exec ${REAL_FIND} "\$@"
EOF
    chmod +x "${STUB}/find"
}

# A `wc` that answers 0 and exits 1: "no files here" with a failure behind it.
_stub_wc_zero_then_fail() {
    _stub wc \
        '#!/bin/sh' \
        'printf "0\n"' \
        'exit 1'
}

# A `grep` whose COUNTING form ($1 = -c or -cv) prints 0 and exits 2 - the
# status that means "I could not read that file", printed as the same 0 a
# clean file gives. Every other grep is the real one.
_stub_grep_count_unreadable() {
    _stub grep \
        '#!/bin/sh' \
        'for a in "$@"; do' \
        "  case \"\$a\" in $1) printf \"0\\n\"; exit 2 ;; esac" \
        'done' \
        "exec ${REAL_GREP} \"\$@\""
}

# A `grep` that prints the managed command line 3.5 expects and exits 1
# ("no match"): the answer looks right, the status says it was never found.
_stub_grep_command_then_no_match() {
    cat >"${STUB}/grep" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    '^command')
      printf "command = 'x' enter dev -- tmux new -A -s main\n"
      exit 1
      ;;
  esac
done
exec ${REAL_GREP} "\$@"
EOF
    chmod +x "${STUB}/grep"
}

# A `mktemp` that creates and prints a real directory and exits 1.
_stub_mktemp_dir_then_fail() {
    _stub mktemp \
        '#!/bin/sh' \
        "${REAL_MKTEMP} \"\$@\"" \
        'exit 1'
}

# --- Control ------------------------------------------------------------------

@test "control: with every tool behaving, all six items pass (so the failure cases below are not vacuous)" {
    run "${VERIFY}"
    assert_success
    assert_output --partial "3.1 PASS"
    assert_output --partial "3.2 PASS"
    assert_output --partial "3.3 PASS"
    assert_output --partial "3.4 PASS"
    assert_output --partial "3.5 PASS"
    assert_output --partial "3.6 PASS"
}

# --- CLI ----------------------------------------------------------------------

@test "cli: --help exits 0 and names every item" {
    run "${VERIFY}" --help
    assert_success
    assert_output --partial "Usage: verify/setup.sh"
    assert_output --partial "3.6"
}

@test "cli: an unknown option exits 2 and names the option" {
    run "${VERIFY}" --bogus
    assert_failure 2
    assert_output --partial "verify/setup.sh: unknown option '--bogus' (see --help)"
}

@test "cli: an unknown item exits 2 and names the item" {
    run "${VERIFY}" 9.9
    assert_failure 2
    assert_output --partial "verify/setup.sh: unknown item '9.9' (see --help)"
}

@test "cli: --list prints the six items with their group" {
    run "${VERIFY}" --list
    assert_success
    assert_line --index 0 --partial "3.1  temphome"
    assert_line --index 5 --partial "3.6  temphome"
    [ "${#lines[@]}" -eq 6 ]
}

# --- 3.1 ----------------------------------------------------------------------

@test "3.1: a just that prints the documented decision lines but exits 1 cannot pass" {
    _stub_just_plausible 1
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.1: a sed that normalises the output correctly but exits 1 cannot pass" {
    _stub_sed_output_then_fail
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "normalising the output"
}

@test "3.1: a find that lists a plausible file but exits 1 cannot pass (the dry-run file count)" {
    _stub_find_list_then_fail
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "counting the files under"
}

@test "3.1: a wc that answers 0 but exits 1 cannot pass (0 files must not mean 0 files)" {
    _stub_wc_zero_then_fail
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "counting the files under"
}

@test "3.1: a mktemp that prints a real directory but exits 1 cannot pass" {
    _stub_mktemp_dir_then_fail
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "mktemp -d failed"
}

@test "3.1: no ghostty on PATH is reported and fails, never skipped" {
    rm -f "${STUB}/ghostty"
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "ghostty is not on PATH"
}

@test "3.1: no distrobox on PATH is reported and fails, never skipped" {
    run env PATH="${NO_DISTROBOX_PATH}" "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "distrobox is not on PATH"
}

@test "3.1: no just on PATH is reported and fails, never skipped" {
    # A PATH holding every tool the check uses EXCEPT just, so the one
    # thing missing is the one the message must name.
    local _d="${BATS_TEST_TMPDIR}/nojust" _t
    mkdir -p "${_d}"
    for _t in env sed find wc mktemp grep ln chmod cat rm mkdir dirname sh bash awk distrobox; do
        ln -s "$(command -v "${_t}")" "${_d}/${_t}"
    done
    ln -s "${STUB}/ghostty" "${_d}/ghostty"
    run env PATH="${_d}" "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "missing on PATH"
    assert_output --partial "just"
}

# --- 3.2 ----------------------------------------------------------------------

@test "3.2: a just that prints the documented write lines but exits 1 cannot pass" {
    _stub_just_plausible 1
    run "${VERIFY}" 3.2
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.2: a just that prints the documented write lines and exits 0 without writing anything cannot pass" {
    _stub_just_plausible 0
    run "${VERIFY}" 3.2
    assert_failure
    assert_output --partial "left no readable"
}

@test "3.2: a sed that normalises the output correctly but exits 1 cannot pass" {
    _stub_sed_output_then_fail
    run "${VERIFY}" 3.2
    assert_failure
    assert_output --partial "normalising"
}

# --- 3.3 ----------------------------------------------------------------------

@test "3.3: a just that prints the documented removal lines but exits 1 cannot pass" {
    _stub_just_plausible 1
    run "${VERIFY}" 3.3
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.3: a sed that normalises the output correctly but exits 1 cannot pass" {
    _stub_sed_output_then_fail
    run "${VERIFY}" 3.3
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.3: a grep -c that answers 0 but exits 2 cannot pass (blocks=0 must mean the file was read)" {
    _stub_grep_count_unreadable '-c'
    run "${VERIFY}" 3.3
    assert_failure
    refute_output --partial "3.3 PASS"
}

# --- 3.4 ----------------------------------------------------------------------

@test "3.4: a just that prints the documented refusal but exits 1 instead of 2 cannot pass" {
    _stub_just_plausible 1
    run "${VERIFY}" 3.4
    assert_failure
    assert_output --partial "expected 2"
}

@test "3.4: a just that prints the documented refusal and exits 0 cannot pass (an accepted --bogus is the bug)" {
    _stub_just_plausible 0
    run "${VERIFY}" 3.4
    assert_failure
    assert_output --partial "expected 2"
}

@test "3.4: a sed that normalises the output correctly but exits 1 cannot pass" {
    _stub_sed_output_then_fail
    run "${VERIFY}" 3.4
    assert_failure
    assert_output --partial "normalising the output"
}

@test "3.4: a find that lists a plausible file but exits 1 cannot pass (the created-nothing count)" {
    _stub_find_list_then_fail
    run "${VERIFY}" 3.4
    assert_failure
    assert_output --partial "counting the files under"
}

# --- 3.5 ----------------------------------------------------------------------

@test "3.5: a just that prints the documented restricted-PATH refusal but exits 1 everywhere cannot pass" {
    _stub_just_plausible 1
    run "${VERIFY}" 3.5
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.5: a sed that normalises the output correctly but exits 1 cannot pass" {
    _stub_sed_output_then_fail
    run "${VERIFY}" 3.5
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.5: a grep that prints the expected command line but exits 1 cannot pass" {
    _stub_grep_command_then_no_match
    run "${VERIFY}" 3.5
    assert_failure
    refute_output --partial "3.5 PASS"
}

@test "3.5: a wc that answers 0 but exits 1 cannot pass (the wrote-nothing count)" {
    _stub_wc_zero_then_fail
    run "${VERIFY}" 3.5
    assert_failure
    assert_output --partial "counting the files under"
}

# --- 3.6 ----------------------------------------------------------------------

@test "3.6: a just that prints a plausible distrobox line but exits 1 cannot pass" {
    _stub_just_plausible 1
    run "${VERIFY}" 3.6
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.6: a just that prints a plausible distrobox line and exits 0 without a managed block cannot pass" {
    _stub_just_plausible 0
    run "${VERIFY}" 3.6
    assert_failure
    refute_output --partial "3.6 PASS"
}

@test "3.6: a sed that stages the bare-name block correctly but exits 1 cannot pass" {
    _stub_sed_output_then_fail
    run "${VERIFY}" 3.6
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.6: a grep -cv that answers 0 but exits 2 cannot pass (stderr=0 must mean stderr was read)" {
    _stub_grep_count_unreadable '-cv'
    run "${VERIFY}" 3.6
    assert_failure
    refute_output --partial "3.6 PASS"
}

# --- Group realbox ------------------------------------------------------------
# The guard is enforced by the dispatcher, so it is exercised the way the
# dispatcher reaches it: by sourcing the script (which defines its
# functions and runs nothing) and calling it.

@test "realbox: an item in the group is refused without the explicit opt-in" {
    run bash -c "source '${VERIFY}'; _realbox_guard 5.1"
    assert_failure
    assert_output --partial "--allow-real-box"
}

@test "realbox: the opt-in is refused when a box named dev already exists" {
    _stub distrobox '#!/bin/sh' 'printf "NAME  STATUS\ndev   Up 2 hours\n"' 'exit 0'
    run bash -c "source '${VERIFY}'; OPT_ALLOW_REAL_BOX=1; _realbox_guard 5.1"
    assert_failure
    assert_output --partial "already exists"
}

@test "realbox: a distrobox list that prints a plausible list but exits 1 refuses instead of creating anything" {
    _stub distrobox '#!/bin/sh' 'printf "NAME  STATUS\n"' 'exit 1'
    run bash -c "source '${VERIFY}'; OPT_ALLOW_REAL_BOX=1; _realbox_guard 5.1"
    assert_failure
    assert_output --partial "cannot tell whether a box named 'dev' exists"
}

@test "realbox: the opt-in passes when no box named dev exists" {
    _stub distrobox '#!/bin/sh' 'printf "NAME  STATUS\nother  Up\n"' 'exit 0'
    run bash -c "source '${VERIFY}'; OPT_ALLOW_REAL_BOX=1; _realbox_guard 5.1"
    assert_success
}

@test "realbox: a box claimed before creation is removed by the shared cleanup" {
    local _calls="${BATS_TEST_TMPDIR}/distrobox.calls"
    _stub distrobox '#!/bin/sh' "printf '%s\n' \"\$*\" >>'${_calls}'" 'exit 0'
    run bash -c "source '${VERIFY}'; _realbox_claim; _cleanup"
    assert_success
    run cat "${_calls}"
    assert_output --partial "rm --force dev"
}

@test "realbox: a box this run did not claim is never removed" {
    local _calls="${BATS_TEST_TMPDIR}/distrobox.calls"
    _stub distrobox '#!/bin/sh' "printf '%s\n' \"\$*\" >>'${_calls}'" 'exit 0'
    run bash -c "source '${VERIFY}'; _cleanup"
    assert_success
    [ ! -e "${_calls}" ]
}

# --- Cleanup ------------------------------------------------------------------

@test "cleanup: a completed run leaves no throwaway HOME behind" {
    run "${VERIFY}" 3.1
    assert_success
    run "${REAL_FIND}" "${TMPDIR}" -mindepth 1 -maxdepth 1
    assert_output ""
}
