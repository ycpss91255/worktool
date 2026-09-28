#!/usr/bin/env bats
# test/unit/verify_diagram_spec.bats - script/verify/diagram.sh cannot false-pass
#
# WHAT THIS PROVES
#   script/verify/diagram.sh is the executable form of the M3 acceptance item
#   4.1 (doc/acceptance.md): the three doc/diagram/*.drawio.svg files, their
#   foreignObject / mxfile properties, the four README references and the flow
#   diagram wording. The document used to carry that logic as a pasteable
#   block of greps, where a failing stage could still leave a plausible number
#   on screen and a zero exit behind.
#
#   These cases are therefore not about the diagrams being right - the real
#   diagrams have test/unit/diagram_spec.bats for that. They are about the
#   CHECKER: for every way the check can be prevented from answering, the
#   script must exit non-zero rather than print a reassuring number.
#
#   Two properties make the surface small enough to cover exhaustively:
#     - the script runs exactly ONE external command, grep (its own location,
#       its usage text and every comparison are shell builtins), and
#     - it contains no pipelines at all, so "the first stage of the pipeline"
#       is, in every check, that single grep call.
#   So the stubs below replace grep - per stage, and globally - and each case
#   asserts a non-zero exit.
#
#   The stubs that matter most PRINT A PLAUSIBLE ANSWER AND STILL FAIL: a file
#   list where grep -l would print one, `4` where the README count belongs,
#   `1` where the flow-wording count belongs. Under the old block those runs
#   were indistinguishable from a pass; here each one must be red. Two more
#   stubs lie about the answer instead of failing - a grep that never matches
#   (which would make `foreignobject=0/3` a free pass) and one that always
#   matches (which would make `mxfile=3/3` one) - and the script's per-file
#   grep self-probe must catch both.
#
#   A control case runs the fixture checkout unmodified and asserts the five
#   documented lines, so every rejection below is proven to be about the
#   injected fault and not about the fixture shape.
#
# Written test-first: RED against a diagram.sh whose grep statuses were not
# triaged (the stub cases passed), GREEN once each status is read, each count
# carries the population it was taken over, and every input is proven usable
# before it is counted.

load "${BATS_TEST_DIRNAME}/../helper/common"

# The five lines doc/acceptance.md shows for item 4.1, in order.
EXPECTED_BLOCK='svg=3
foreignobject=0/3
mxfile=3/3
readme=4
flow-wording=1'

setup() {
    SCRIPT="${REPO_ROOT}/script/verify/diagram.sh"
    FIXTURE_ROOT="${BATS_TEST_TMPDIR}/root"
    STUB_BIN="${BATS_TEST_TMPDIR}/stub"
    # Absolute, so the "no grep on PATH" case can empty PATH and still start
    # a shell (otherwise the case would fail on `bash: not found` instead of
    # on the missing grep).
    BASH_BIN="$(command -v bash)"
    _make_root "${FIXTURE_ROOT}"
}

# --- Fixture checkout --------------------------------------------------------

# Build a throwaway checkout under $1 that item 4.1 can be pointed at: the
# three real diagrams, the real README, and the marker file --root looks for
# (its content never runs). Individual cases then break exactly one thing.
_make_root() {
    local _root="$1"
    mkdir -p "${_root}/doc/diagram" "${_root}/script/verify"
    cp "${REPO_ROOT}/doc/diagram/"*.drawio.svg "${_root}/doc/diagram/"
    cp "${REPO_ROOT}/README.md" "${_root}/README.md"
    printf '#!/usr/bin/env bash\n# marker only\n' > "${_root}/script/verify/diagram.sh"
}

# --- grep stubs --------------------------------------------------------------

# A grep that fails only when one argument contains $2, after printing $3 (so
# the run still looks plausible on screen), and delegates every other call to
# the real grep. $1 = directory to put it in, $4 = exit status.
#
# The real grep path is baked in at write time, so the stub keeps working
# after PATH has been pointed at it.
_write_grep_stub_stage() {
    local _dir="$1" _target="$2" _output="$3" _status="$4" _real
    _real="$(command -v grep)"
    mkdir -p "${_dir}"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'REAL_GREP=%q\n' "${_real}"
        printf 'TARGET=%q\n' "${_target}"
        printf 'OUTPUT=%q\n' "${_output}"
        printf 'STATUS=%q\n' "${_status}"
        cat <<'STUB'
for _a in "$@"; do
    case "${_a}" in
        *"${TARGET}"*)
            [ -n "${OUTPUT}" ] && printf '%s\n' "${OUTPUT}"
            exit "${STATUS}"
            ;;
    esac
done
exec "${REAL_GREP}" "$@"
STUB
    } > "${_dir}/grep"
    chmod +x "${_dir}/grep"
}

# A grep that answers every call the same way: status $2, printing $3. Used
# for the two liars - "nothing ever matches" and "everything always matches" -
# which do not fail at all, they just make the wrong answer look right.
_write_grep_stub_always() {
    local _dir="$1" _status="$2" _output="$3"
    mkdir -p "${_dir}"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'OUTPUT=%q\n' "${_output}"
        printf 'STATUS=%q\n' "${_status}"
        cat <<'STUB'
[ -n "${OUTPUT}" ] && printf '%s\n' "${OUTPUT}"
exit "${STATUS}"
STUB
    } > "${_dir}/grep"
    chmod +x "${_dir}/grep"
}

# --- Runners -----------------------------------------------------------------

# Run the script with stdout only (stderr dropped) so the printed block can be
# compared byte for byte with the document.
_run_stdout() {
    run bash -c 'bash "$@" 2>/dev/null' _ "${SCRIPT}" "$@"
}

# Run the script with $STUB_BIN first on PATH.
_run_with_stub() {
    run env PATH="${STUB_BIN}:${PATH}" bash "${SCRIPT}" "$@"
}

# --- Control: the fixture is good, and the block is the documented one ------

@test "4.1: the real checkout prints exactly the five documented lines on stdout" {
    _run_stdout --root "${REPO_ROOT}" 4.1
    assert_success
    assert_output "${EXPECTED_BLOCK}"
}

@test "4.1: the fixture checkout passes unmodified (control for every rejection below)" {
    _run_stdout --root "${FIXTURE_ROOT}" 4.1
    assert_success
    assert_output "${EXPECTED_BLOCK}"
}

@test "a bare run checks the same items as an explicit 4.1 run" {
    _run_stdout --root "${FIXTURE_ROOT}"
    assert_success
    assert_output "${EXPECTED_BLOCK}"
}

# --- Command line ------------------------------------------------------------

@test "--help exits 0 and prints the usage" {
    run bash "${SCRIPT}" --help
    assert_success
    assert_line --partial "Usage: diagram.sh"
}

@test "an unknown option exits 2 and names the option" {
    run bash "${SCRIPT}" --bogus
    assert_failure 2
    assert_line --partial "unknown option '--bogus'"
}

@test "an unknown item exits 2 and names the item" {
    run bash "${SCRIPT}" 9.9
    assert_failure 2
    assert_line --partial "unknown item '9.9'"
}

@test "--root without an argument exits 2 before anything runs" {
    run bash "${SCRIPT}" --root
    assert_failure 2
    assert_line --partial "--root requires a path argument"
}

@test "--root pointing at something that is not a worktool checkout exits 2" {
    run bash "${SCRIPT}" --root "${BATS_TEST_TMPDIR}" 4.1
    assert_failure 2
    assert_line --partial "not a worktool checkout"
}

@test "--realbox enables nothing here and says so (this script has no real-machine item)" {
    run bash "${SCRIPT}" --root "${FIXTURE_ROOT}" --realbox 4.1
    assert_success
    assert_line --partial "declares no real-machine items"
}

# --- 4.1: the inputs must be proven to exist before anything is counted ------

@test "4.1: a missing doc/diagram directory fails instead of counting zero" {
    rm -rf "${FIXTURE_ROOT}/doc/diagram"
    run bash "${SCRIPT}" --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line --partial "not a directory"
    refute_line --partial "svg="
}

@test "4.1: an empty doc/diagram fails - nothing matched is not zero problems found" {
    rm -f "${FIXTURE_ROOT}/doc/diagram/"*.drawio.svg
    run bash "${SCRIPT}" --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line --partial "no .drawio.svg under"
    # The degenerate 0/0 block must never be printed at all.
    refute_line --partial "svg=0"
    refute_line --partial "foreignobject=0/0"
}

@test "4.1: a zero-byte diagram fails instead of contributing a clean zero" {
    : > "${FIXTURE_ROOT}/doc/diagram/architecture.drawio.svg"
    run bash "${SCRIPT}" --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line --partial "is empty"
}

@test "4.1: a dangling symlink in place of a diagram fails and is named as one" {
    rm -f "${FIXTURE_ROOT}/doc/diagram/architecture.drawio.svg"
    ln -s "${FIXTURE_ROOT}/doc/diagram/gone.svg" \
        "${FIXTURE_ROOT}/doc/diagram/architecture.drawio.svg"
    run bash "${SCRIPT}" --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line --partial "dangling symlink"
}

@test "4.1: a missing README.md fails before any line is printed" {
    rm -f "${FIXTURE_ROOT}/README.md"
    run bash "${SCRIPT}" --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line --partial "does not exist"
    refute_line --partial "svg="
}

# --- 4.1: the tool must be there, and must not be believed blindly ----------

@test "4.1: says so and fails when grep is not available at all" {
    mkdir -p "${STUB_BIN}"
    run env PATH="${STUB_BIN}" "${BASH_BIN}" "${SCRIPT}" --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line --partial "grep is not available here"
}

@test "4.1: fails when grep never matches anything (would make foreignobject=0/3 a free pass)" {
    _write_grep_stub_always "${STUB_BIN}" 1 ""
    _run_with_stub --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line --partial "always-matches probe"
    refute_line --partial "foreignobject=0/3"
}

@test "4.1: fails when grep always matches (would make mxfile=3/3 a free pass)" {
    _write_grep_stub_always "${STUB_BIN}" 0 ""
    _run_with_stub --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line --partial "never-matches probe"
    refute_line --partial "mxfile=3/3"
}

# --- 4.1: each stage's grep fails while printing a plausible answer ----------

@test "4.1: fails when the foreignObject scan breaks while printing a plausible file list" {
    _write_grep_stub_stage "${STUB_BIN}" '<foreignObject' \
        "${FIXTURE_ROOT}/doc/diagram/architecture.drawio.svg" 2
    _run_with_stub --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line --partial "grep exited 2 while scanning"
    refute_line --partial "foreignobject=0/3"
}

@test "4.1: fails when the mxfile scan breaks while printing a plausible file list" {
    _write_grep_stub_stage "${STUB_BIN}" 'content="&lt;mxfile' \
        "${FIXTURE_ROOT}/doc/diagram/flow.drawio.svg" 2
    _run_with_stub --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line --partial "grep exited 2 while scanning"
    refute_line --partial "mxfile=3/3"
}

@test "4.1: fails when the README count breaks while printing a plausible 4" {
    _write_grep_stub_stage "${STUB_BIN}" 'doc/diagram/.*\.drawio\.svg' 4 2
    _run_with_stub --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line --partial "grep exited 2 while counting"
    refute_line --partial "readme=4"
}

@test "4.1: fails when the flow-wording count breaks while printing a plausible 1" {
    _write_grep_stub_stage "${STUB_BIN}" 'host 只需 docker + just' 1 2
    _run_with_stub --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line --partial "grep exited 2 while counting"
    refute_line --partial "flow-wording=1"
}

@test "4.1: fails when grep -c answers with something that is not a count" {
    _write_grep_stub_stage "${STUB_BIN}" 'doc/diagram/.*\.drawio\.svg' four 0
    _run_with_stub --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line --partial "not a count"
    refute_line --partial "readme=four"
}

# --- 4.1: real regressions in the diagrams still fail -----------------------

@test "4.1: fails when a fourth .drawio.svg appears" {
    cp "${FIXTURE_ROOT}/doc/diagram/flow.drawio.svg" \
        "${FIXTURE_ROOT}/doc/diagram/extra.drawio.svg"
    run bash "${SCRIPT}" --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line "svg=4"
    assert_line --partial "svg: got '4', expected '3'"
}

@test "4.1: fails when a diagram carries a <foreignObject>" {
    printf '<foreignObject/>\n' >> "${FIXTURE_ROOT}/doc/diagram/architecture.drawio.svg"
    run bash "${SCRIPT}" --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line "foreignobject=1/3"
    assert_line --partial "foreignobject-hits: got '1', expected '0'"
}

@test "4.1: fails when a diagram lost its embedded mxfile source" {
    printf '<svg xmlns="http://www.w3.org/2000/svg"><text>x</text></svg>\n' \
        > "${FIXTURE_ROOT}/doc/diagram/architecture.drawio.svg"
    run bash "${SCRIPT}" --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line "mxfile=2/3"
    assert_line --partial "mxfile-hits: got '2', expected '3'"
}

@test "4.1: fails when README references only three of the diagram files" {
    grep -v 'doc/diagram/\*\.drawio\.svg' "${REPO_ROOT}/README.md" \
        > "${FIXTURE_ROOT}/README.md"
    run bash "${SCRIPT}" --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line "readme=3"
    assert_line --partial "readme: got '3', expected '4'"
}

@test "4.1: fails when the flow diagram lost the 'host 只需 docker + just' wording" {
    sed -i 's/host 只需 docker + just/host 不裝任何套件/g' \
        "${FIXTURE_ROOT}/doc/diagram/flow.drawio.svg"
    run bash "${SCRIPT}" --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_line "flow-wording=0"
    assert_line --partial "flow-wording: got '0', expected '1'"
}

@test "4.1: a run that fails on a count still prints the whole five-line block first" {
    grep -v 'doc/diagram/\*\.drawio\.svg' "${REPO_ROOT}/README.md" \
        > "${FIXTURE_ROOT}/README.md"
    _run_stdout --root "${FIXTURE_ROOT}" 4.1
    assert_failure
    assert_output 'svg=3
foreignobject=0/3
mxfile=3/3
readme=3
flow-wording=1'
}
