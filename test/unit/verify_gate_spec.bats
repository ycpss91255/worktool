#!/usr/bin/env bats
# test/unit/verify_gate_spec.bats - script/verify/gate.sh cannot false-pass
#
# WHAT THIS PROVES
#   script/verify/gate.sh is the executable form of doc/acceptance.md's M3
#   items 2.1-2.4 (the automated gates, the TDD evidence, and the negative
#   that proves the acceptance machinery itself bites). An acceptance check
#   is worth nothing unless a broken check reads RED, so this spec attacks
#   the script from the only direction that matters: it makes each stage
#   FAIL WHILE STILL PRINTING PLAUSIBLE OUTPUT and asserts the script still
#   exits non-zero.
#
#   The stages, and the case that breaks each one:
#     just test              - exits 1 after printing a whole green run
#     just test              - never returns (killed by GATE_TIMEOUT)
#     just test integration  - exits 1 after printing the documented ok lines
#     just test <tier>       - exits 0 having printed no documented line
#     just test <tier>       - exits 0 with a `not ok` case in the stream
#     doc/evidence/tdd.sh    - exits 1 after printing ten `order=ok` lines
#     doc/evidence/tdd.sh    - exits 0 after printing an `order=BAD` line
#     doc/evidence/tdd.sh    - exits 0 printing nothing
#     awk over a fixture     - exits 0 while printing the documented verdict
#     awk over a fixture     - exits 1 while printing a different verdict
#
#   And the degenerate shape that is the whole point of items 2.2 and 2.3 -
#   a GREEN run whose evidence is almost entirely ABSENT, which "at least
#   one line matched" used to accept:
#     doc/evidence/tdd.sh    - exits 0 with one verdict instead of ten
#     doc/evidence/tdd.sh    - exits 0 judging one PR twice and one never
#     doc/evidence/tdd.sh    - exits 0 judging a PR the item does not cover
#     doc/evidence/tdd.sh    - exits 0 with GREEN opening before RED
#     doc/evidence/tdd.sh    - exits 0 with ten correct verdicts, two swapped
#     just test system-real  - exits 0 with SECOND_ELAPSED outside the 0-15
#                              the document publishes
#     just test <tier>       - exits 0 with one placeholder `ok` per tier
#     just test system-real  - exits 0 with only a subset of the criteria
#     just test system-real  - exits 0 with plausible-but-wrong values
#     just test system-real  - exits 0 repeating a documented case
#     just test integration  - exits 0 with a case the document never listed
#     just test system-real  - exits 0 with the hang 124 BEFORE its ready
#                              marker (a start-up hang wearing the bounded
#                              case's clothes)
#   plus the control that keeps those from over-reaching: a run whose
#   per-run MEASUREMENTS (host, fish version, elapsed, delay) all differ
#   still passes, because the document says not to compare those literally.
#
#   The 2.2 cases above replace doc/evidence/tdd.sh, so two more keep the
#   REAL tdd.sh and the REAL tdd.awk and attack the layer below them: a `gh`
#   that prints a PASSING PR body and then exits non-zero must not read as
#   evidence, and the same gh exiting 0 must (that control is what makes the
#   negative non-vacuous, and pins tdd.sh's own PR list to gate.sh's).
#
#   Plus the data-side regression (a negative fixture that has silently
#   become a PASSING body), the UNAVAILABLE contract (a missing docker / gh
#   / awk / fixture exits non-zero and says so - the script never skips),
#   and the CLI contract (--help 0, unknown option 2 naming the option,
#   unknown item 2, --list).
#
# HOW
#   Items 2.1-2.3 drive tools this image does not have (docker, gh), so the
#   cases run against an independent COPY of the checkout under
#   $BATS_TEST_TMPDIR with stubs first on PATH. The copy is what lets the
#   2.2 cases replace doc/evidence/tdd.sh and the 2.4 cases replace a
#   negative fixture without touching the real tree. Item 2.4 needs nothing
#   external, so its control case runs the REAL script against the REAL
#   checkout - which is what keeps the negative assertions from being
#   vacuous.
#
#   No Docker and no network: `just`, `docker` and `gh` are never the real
#   ones here.

load "${BATS_TEST_DIRNAME}/../helper/common"

GATE_SH="${REPO_ROOT}/script/verify/gate.sh"

setup() {
    BIN="${BATS_TEST_TMPDIR}/bin"
    COPY="${BATS_TEST_TMPDIR}/copy"
    INT_BLOCK="${BATS_TEST_TMPDIR}/integration.block"
    SYS_BLOCK="${BATS_TEST_TMPDIR}/system-real.block"
    mkdir -p "${BIN}"
    _make_repo_copy
    COPY_GATE="${COPY}/script/verify/gate.sh"
}

# An independent checkout copy holding everything gate.sh reads: its own
# location (script/verify), the justfile its ci preconditions require, and
# the doc/evidence assets items 2.2 and 2.4 run.
_make_repo_copy() {
    mkdir -p "${COPY}/script/verify" "${COPY}/doc"
    cp "${REPO_ROOT}/justfile" "${COPY}/justfile"
    cp "${REPO_ROOT}/script/verify/gate.sh" "${COPY}/script/verify/gate.sh"
    cp -R "${REPO_ROOT}/doc/evidence" "${COPY}/doc/evidence"
}

# _stub <name> - body on stdin. The body runs with $REAL set to the real
# executable of that name (resolved before PATH is touched), so a stub can
# delegate every call it does not want to break: `exec "${REAL}" "$@"`.
_stub() {
    local _name="$1" _real=""
    _real="$(command -v "${_name}")" || _real=""
    {
        printf '#!/usr/bin/env bash\n'
        printf 'REAL=%q\n' "${_real}"
        cat
    } >"${BIN}/${_name}"
    chmod +x "${BIN}/${_name}"
}

# The tools the `ci` group demands but this image does not ship. Both are
# inert: every case that cares about their behaviour stubs `just` itself.
_stub_ci_tools() {
    _stub docker <<'EOF'
exit 0
EOF
}

# Replace the copy's doc/evidence/tdd.sh with a stub whose body is on stdin.
_stub_tdd_sh() {
    {
        printf '#!/usr/bin/env bash\n'
        cat
    } >"${COPY}/doc/evidence/tdd.sh"
    chmod +x "${COPY}/doc/evidence/tdd.sh"
}

# A `gh` that must never actually be called: item 2.2 only requires it to
# EXIST (doc/evidence/tdd.sh is the thing that would use it, and the 2.2
# cases that stub that script never reach gh).
_stub_gh() {
    _stub gh <<'EOF'
printf 'fake gh: must not be called: gh %s\n' "$*" >&2
exit 99
EOF
}

# A PR body of exactly the shape item 2.2 accepts: a non-empty RED block and
# a LATER non-empty GREEN block. It is deliberately a PASSING body, so a
# checker that read what gh printed without reading gh's exit status would
# answer `order=ok` for it.
_plausible_pr_body() {
    cat <<'EOF'
## RED

```text
not ok 1 the feature does not exist yet
```

## GREEN

```text
ok 1 the feature exists
```
EOF
}

# A `gh` that prints that passing body for every query and then exits $1.
# Used by the cases that run the REAL doc/evidence/tdd.sh, which is the only
# way to prove the delivered checker fails closed rather than the stub.
_stub_gh_body() {
    local _exit="$1" _body="${BATS_TEST_TMPDIR}/pr-body.md"
    _plausible_pr_body >"${_body}"
    _stub gh <<EOF
cat -- $(printf '%q' "${_body}")
exit ${_exit}
EOF
}

# Ten passing verdicts, exactly the shape doc/acceptance.md publishes.
_ten_ok_verdicts() {
    cat <<'EOF'
printf '#152 order=ok red=31 green=51\n'
printf '#153 order=ok red=21 green=40\n'
printf '#154 order=ok red=27 green=41\n'
printf '#155 order=ok red=31 green=49\n'
printf '#156 order=ok red=29 green=49\n'
printf '#165 order=ok red=25 green=72\n'
printf '#166 order=ok red=21 green=58\n'
printf '#167 order=ok red=20 green=56\n'
printf '#168 order=ok red=25 green=44\n'
printf '#169 order=ok red=22 green=47\n'
EOF
}

# --- Item 2.3 fixtures -------------------------------------------------------
# The two blocks doc/acceptance.md publishes for item 2.3, verbatim. They are
# written to files that a `just` stub cats, so a degenerate case can mutate
# ONE line of an otherwise complete, otherwise-passing block - which is what
# makes it a test of the assertion under attack and not of the fixture.

_integration_block() {
    cat <<'EOF'
ok 8 setup then status: status reports the stored decisions, sources and the ghostty block present, no tmux line
ok 1 preflight: a real ghostty is on PATH and reports its version
ok 2 setup.sh writes a ghostty config that +validate-config accepts
ok 5 +show-config follows setup.sh --box work (the box name reaches ghostty)
ok 6 #175: the effective command ghostty resolves is an ABSOLUTE distrobox path, not the bare name
ok 9 #175r2: a distrobox path holding a newline is refused, because ghostty could not parse what it would write
ok 10 #175r1: a distrobox path with spaces and metacharacters survives ghostty and the shell it hands the command to
ok 11 after setup.sh --auto-enter no there is no enter command left for ghostty to run
ok 12 +validate-config refuses a config ghostty cannot parse (the check bites)
EOF
}

_system_real_block() {
    cat <<'EOF'
ok 12 ghostty chain: the managed block pins gtk-single-instance = false (no D-Bus false positive)
# chain: inbox-ok fish=4.2.1 ctrenv=/run/.containerenv mntns=mnt:[1234] tmux=no host=ca83e9d035cd
# chain-in-box: marker mntns=mnt:[1234] == dev container; host=ca83e9d035cd == docker inspect dev hostname
ok 13 ghostty chain: a real window runs the managed block's command and leaves a marker INSIDE the box (fish, the box's mount namespace, no tmux)
# hang-ready: hang-ready fish=4.2.1 host=ca83e9d035cd
# hang: in-box command started, then timed out after 45s (budget 45s, status 124)
ok 14 ghostty chain: a command that has STARTED inside the box and never ends FAILS within its budget instead of hanging
# single-instance: PRIMARY=up
# single-instance: SECOND_RC=0
# single-instance: SECOND_ELAPSED=1
# single-instance: STARTED_AT_RETURN=1
# single-instance: FORWARDED_STARTED=yes
# single-instance: FORWARDED_AFTER_RETURN=yes
# single-instance: FORWARDED_DELAY_MS=319
# single-instance: RUNNING_COMMANDS=2
# single-instance: PRIMARY_WRAPPER_ALIVE=yes
# single-instance: COMMAND_FINISHED=no
ok 15 ghostty chain: with gtk-single-instance on, a forwarded launch exits 0 while the command it asked for has not begun yet (the false positive the guard prevents)
# chain-desktop-path: inbox-ok fish=4.2.1 ctrenv=/run/.containerenv mntns=mnt:[1234] tmux=no host=ca83e9d035cd
ok 16 ghostty chain (#175): the absolute distrobox path just box setup writes enters the box from a desktop session's PATH
EOF
}

# Write both blocks in their documented (passing) form. INT_BLOCK and
# SYS_BLOCK are the files a case mutates before stubbing `just`.
_write_tier_blocks() {
    _integration_block >"${INT_BLOCK}"
    _system_real_block >"${SYS_BLOCK}"
}

# A `just` whose `test <tier>` prints the file for that tier. $1 is the exit
# status of the integration tier, $2 of the system-real tier (both 0).
_stub_just_blocks() {
    local _int_rc="${1:-0}" _sys_rc="${2:-0}"
    _stub just <<EOF
case "\${2:-}" in
    integration) cat -- $(printf '%q' "${INT_BLOCK}"); exit ${_int_rc} ;;
    system-real) cat -- $(printf '%q' "${SYS_BLOCK}"); exit ${_sys_rc} ;;
esac
printf 'fake just: unexpected: %s\n' "\$*" >&2
exit 99
EOF
}

# The documented blocks, unmutated, behind a `just` that exits $1 / $2.
_stub_just_tiers() {
    _write_tier_blocks
    _stub_just_blocks "${1:-0}" "${2:-0}"
}

# --- Controls: the real thing, so the negatives are not vacuous --------------

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "control: item 2.4 passes against this checkout and prints the documented six lines" {
    # stderr dropped on purpose: the contract is that STDOUT alone is the
    # block doc/acceptance.md publishes, in that order.
    run bash -c '"$1" 2.4 2>/dev/null' _ "${GATE_SH}"
    assert_success
    assert_line --index 0 'order=BAD red=6 green=0'
    assert_line --index 1 'wrong-order rc=1'
    assert_line --index 2 'order=BAD red=0 green=0'
    assert_line --index 3 'empty-red-block rc=1'
    assert_line --index 4 'guarded-rc=7'
    assert_line --index 5 'unguarded-rc=0'
}

@test "control: item 2.4 against the copy passes too, so every stub below differs in ONE way" {
    run "${COPY_GATE}" 2.4
    assert_success
    assert_line 'guarded-rc=7'
    assert_line 'unguarded-rc=0'
}

# --- Item 2.4: the checker must REFUSE a bad body, not merely describe it ----

@test "false-pass guard: an awk printing the documented verdict but exiting 0 fails" {
    _stub awk <<'EOF'
for _a in "$@"; do
    case "${_a}" in
        *wrong-order.md)
            printf 'order=BAD red=6 green=0\n'
            exit 0
            ;;
    esac
done
exec "${REAL}" "$@"
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.4
    assert_failure 1
    assert_output --partial 'the checker exited 0, expected 1'
}

@test "false-pass guard: an awk exiting 1 with a different verdict fails and names both" {
    _stub awk <<'EOF'
for _a in "$@"; do
    case "${_a}" in
        *empty-red-block.md)
            printf 'order=BAD red=9 green=0\n'
            exit 1
            ;;
    esac
done
exec "${REAL}" "$@"
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.4
    assert_failure 1
    assert_output --partial "expected 'order=BAD red=0 green=0', got 'order=BAD red=9 green=0'"
}

@test "degenerate: a negative fixture that has become a PASSING body fails the item" {
    cat >"${COPY}/doc/evidence/negative/wrong-order.md" <<'EOF'
RED

```text
it failed
```

GREEN

```text
it passed
```
EOF
    run "${COPY_GATE}" 2.4
    assert_failure 1
    assert_output --partial 'wrong-order.md'
    assert_output --partial 'expected 1 (a bad fixture must be refused)'
}

@test "unavailable: a missing negative fixture is reported and exits 3, never skipped" {
    rm -f "${COPY}/doc/evidence/negative/empty-red-block.md"
    run "${COPY_GATE}" 2.4
    assert_failure 3
    assert_output --partial '[UNAVAILABLE]'
    assert_output --partial 'empty-red-block.md is missing'
}

@test "unavailable: a missing awk is reported and exits 3, never skipped" {
    local _stripped="${BATS_TEST_TMPDIR}/noawk"
    mkdir -p "${_stripped}"
    local _tool
    for _tool in bash grep timeout mktemp; do
        ln -sf "$(command -v "${_tool}")" "${_stripped}/${_tool}"
    done
    PATH="${_stripped}" run "${COPY_GATE}" 2.4
    assert_failure 3
    assert_output --partial '[UNAVAILABLE]'
    assert_output --partial 'awk not found on PATH'
}

# --- Item 2.2: the TDD evidence, and the ways it could read green -----------

@test "control: a tdd.sh printing ten order=ok verdicts and exiting 0 passes" {
    _stub_gh
    {
        _ten_ok_verdicts
        printf 'exit 0\n'
    } | _stub_tdd_sh
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.2
    assert_success
    assert_line '#152 order=ok red=31 green=51'
    assert_line '#169 order=ok red=22 green=47'
}

@test "false-pass guard: ten order=ok verdicts followed by exit 1 fails" {
    _stub_gh
    {
        _ten_ok_verdicts
        printf 'exit 1\n'
    } | _stub_tdd_sh
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.2
    assert_failure 1
    assert_output --partial 'exited 1 - what it printed does not count'
}

@test "false-pass guard: an order=BAD verdict with exit 0 is refused, not counted as clean" {
    _stub_gh
    _stub_tdd_sh <<'EOF'
printf '#152 order=ok red=31 green=51\n'
printf '#153 order=BAD red=0 green=0\n'
exit 0
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.2
    assert_failure 1
    assert_output --partial 'not a passing verdict: #153 order=BAD red=0 green=0'
}

@test "degenerate: a tdd.sh exiting 0 with no output fails as empty, not as no-bad-PRs" {
    _stub_gh
    _stub_tdd_sh <<'EOF'
exit 0
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.2
    assert_failure 1
    assert_output --partial "printed nothing - that is not 'every PR passed'"
}

# --- Item 2.2: the SET of verdicts, not just their shape ---------------------
# The item claims ten PR bodies were each judged once. Every case here
# prints verdicts of the documented shape, exits 0, and is still wrong about
# WHICH PRs were judged.

@test "degenerate: a single order=ok verdict fails 2.2 and names the nine PRs with no verdict" {
    _stub_gh
    _stub_tdd_sh <<'EOF'
printf '#152 order=ok red=1 green=2\n'
exit 0
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.2
    assert_failure 1
    assert_output --partial 'printed no passing verdict for 9 of the 10 documented PR(s): #153 #154 #155 #156 #165 #166 #167 #168 #169'
}

@test "degenerate: ten verdicts that judge one PR twice and another not at all fail 2.2 and name both" {
    _stub_gh
    # Ten lines, every one of them well-formed - and still not the ten PRs.
    _stub_tdd_sh <<'EOF'
printf '#152 order=ok red=31 green=51\n'
printf '#152 order=ok red=31 green=51\n'
printf '#153 order=ok red=21 green=40\n'
printf '#154 order=ok red=27 green=41\n'
printf '#155 order=ok red=31 green=49\n'
printf '#156 order=ok red=29 green=49\n'
printf '#165 order=ok red=25 green=72\n'
printf '#166 order=ok red=21 green=58\n'
printf '#167 order=ok red=20 green=56\n'
printf '#168 order=ok red=25 green=44\n'
exit 0
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.2
    assert_failure 1
    assert_output --partial 'printed no passing verdict for 1 of the 10 documented PR(s): #169'
    assert_output --partial 'printed more than one verdict for: #152 (2x)'
}

@test "degenerate: a verdict for a PR this item does not cover fails 2.2 and names it" {
    _stub_gh
    {
        _ten_ok_verdicts
        printf "printf '#999 order=ok red=31 green=51\\\\n'\n"
        printf 'exit 0\n'
    } | _stub_tdd_sh
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.2
    assert_failure 1
    assert_output --partial 'printed a verdict for PR(s) this item does not cover: #999'
}

@test "degenerate: a plausible verdict whose GREEN block opens before its RED block fails 2.2" {
    _stub_gh
    _stub_tdd_sh <<'EOF'
printf '#152 order=ok red=51 green=31\n'
printf '#153 order=ok red=21 green=40\n'
printf '#154 order=ok red=27 green=41\n'
printf '#155 order=ok red=31 green=49\n'
printf '#156 order=ok red=29 green=49\n'
printf '#165 order=ok red=25 green=72\n'
printf '#166 order=ok red=21 green=58\n'
printf '#167 order=ok red=20 green=56\n'
printf '#168 order=ok red=25 green=44\n'
printf '#169 order=ok red=22 green=47\n'
exit 0
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.2
    assert_failure 1
    assert_output --partial 'GREEN must open after RED): #152 order=ok red=51 green=31'
}

@test "degenerate: ten correct verdicts with two of them swapped fail 2.2 on the documented order" {
    _stub_gh
    # Every line is well formed, every documented PR is judged exactly once,
    # and the set comparison is satisfied - only #154 and #155 have traded
    # places, which is a checker walking a list that is not the one this item
    # names.
    _stub_tdd_sh <<'EOF'
printf '#152 order=ok red=31 green=51\n'
printf '#153 order=ok red=21 green=40\n'
printf '#155 order=ok red=31 green=49\n'
printf '#154 order=ok red=27 green=41\n'
printf '#156 order=ok red=29 green=49\n'
printf '#165 order=ok red=25 green=72\n'
printf '#166 order=ok red=21 green=58\n'
printf '#167 order=ok red=20 green=56\n'
printf '#168 order=ok red=25 green=44\n'
printf '#169 order=ok red=22 green=47\n'
exit 0
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.2
    assert_failure 1
    assert_output --partial 'printed the ten verdicts in the order #152 #153 #155 #154'
    assert_output --partial 'but doc/acceptance.md publishes #152 #153 #154 #155'
}

@test "false-pass guard: a tdd.sh that never returns is killed and fails" {
    _stub_gh
    {
        _ten_ok_verdicts
        printf 'exec sleep 20\n'
    } | _stub_tdd_sh
    VERIFY_TIMEOUT=1 PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.2
    assert_failure 1
    assert_output --partial 'did not finish within 1s (timeout)'
}

# --- Item 2.2: the DELIVERED tdd.sh, not a stand-in --------------------------
# Every case above replaces doc/evidence/tdd.sh, so none of them says
# anything about the script the item actually runs. These two do: they keep
# the real tdd.sh and the real tdd.awk of the copy and attack the layer
# below it, the `gh` it reads its evidence from.

@test "control: the real tdd.sh, against a gh that prints a passing body, passes 2.2 with all ten documented verdicts" {
    _stub_gh_body 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.2
    assert_success
    # Ten lines, one per documented PR - which also pins the delivered
    # tdd.sh's own default PR list to the set gate.sh asserts.
    local _pr
    for _pr in 152 153 154 155 156 165 166 167 168 169; do
        assert_line "#${_pr} order=ok red=3 green=9"
    done
}

@test "false-pass guard: the real tdd.sh fails closed when gh prints a plausible passing body and then exits non-zero" {
    _stub_gh_body 1
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.2
    assert_failure 1
    # The body gh printed WOULD have read order=ok (the control above proves
    # it). tdd.sh reports the query failure instead, and gate.sh refuses it.
    assert_output --partial '#152 evidence=gh-failed'
    assert_output --partial 'not a passing verdict: #152 evidence=gh-failed'
    refute_output --partial '#152 order=ok'
}

@test "unavailable: a missing gh is reported and exits 3, never skipped" {
    {
        _ten_ok_verdicts
        printf 'exit 0\n'
    } | _stub_tdd_sh
    local _stripped="${BATS_TEST_TMPDIR}/nogh"
    mkdir -p "${_stripped}"
    local _tool
    for _tool in bash timeout grep mktemp; do
        ln -sf "$(command -v "${_tool}")" "${_stripped}/${_tool}"
    done
    PATH="${_stripped}" run "${COPY_GATE}" 2.2
    assert_failure 3
    assert_output --partial '[UNAVAILABLE]'
    assert_output --partial 'gh not found on PATH'
}

# --- Item 2.1: the six-tier run is judged by its own status ------------------

@test "control: a just test exiting 0 passes item 2.1" {
    _stub_ci_tools
    _stub just <<'EOF'
printf '[ci] ShellCheck OK\n'
printf '[ci] system-real bats OK\n'
exit 0
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.1
    assert_success
    assert_line '[ci] system-real bats OK'
}

@test "false-pass guard: a just test printing a whole green run but exiting 1 fails 2.1" {
    _stub_ci_tools
    _stub just <<'EOF'
printf '[ci] ShellCheck OK\n'
printf '[ci]   required specs OK (331 case(s) declared by 15 file(s))\n'
printf '[ci] system-real bats OK\n'
exit 1
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.1
    assert_failure 1
    assert_output --partial 'exited 1 - the six-tier gate is not green'
}

@test "false-pass guard: a just test that never returns is killed and fails 2.1" {
    _stub_ci_tools
    _stub just <<'EOF'
printf '[ci] ShellCheck OK\n'
exec sleep 20
EOF
    GATE_TIMEOUT=1 PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.1
    assert_failure 1
    assert_output --partial 'did not finish within 1s (timeout)'
}

@test "unavailable: a missing docker is reported and exits 3, never skipped" {
    _stub just <<'EOF'
exit 0
EOF
    local _stripped="${BATS_TEST_TMPDIR}/nodocker"
    mkdir -p "${_stripped}"
    local _tool
    for _tool in bash timeout grep mktemp; do
        ln -sf "$(command -v "${_tool}")" "${_stripped}/${_tool}"
    done
    ln -sf "${BIN}/just" "${_stripped}/just"
    PATH="${_stripped}" run "${COPY_GATE}" 2.1
    assert_failure 3
    assert_output --partial '[UNAVAILABLE]'
    assert_output --partial 'docker not found on PATH'
}

# --- Item 2.3: the chain evidence of the two tiers ---------------------------

@test "control: both tiers printing the documented lines and exiting 0 pass item 2.3" {
    _stub_ci_tools
    _stub_just_tiers 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_success
    assert_line 'ok 1 preflight: a real ghostty is on PATH and reports its version'
    assert_line '# chain: inbox-ok fish=4.2.1 ctrenv=/run/.containerenv mntns=mnt:[1234] tmux=no host=ca83e9d035cd'
    assert_line "ok 13 ghostty chain: a real window runs the managed block's command and leaves a marker INSIDE the box (fish, the box's mount namespace, no tmux)"
    assert_line '# single-instance: COMMAND_FINISHED=no'
}

@test "false-pass guard: the integration tier printing its ok lines but exiting 1 fails 2.3" {
    _stub_ci_tools
    _stub_just_tiers 1 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'ok 1 preflight: a real ghostty is on PATH'
    assert_output --partial 'just test integration'
    assert_output --partial 'exited 1 - what it printed does not count'
}

@test "false-pass guard: a red integration tier stops 2.3 before the system-real tier runs" {
    _stub_ci_tools
    _stub_just_tiers 1 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    refute_output --partial '# chain: inbox-ok'
}

@test "degenerate: a tier exiting 0 with no documented line fails, never reads as clean" {
    _stub_ci_tools
    _stub just <<'EOF'
printf '[ci] integration bats OK\n'
exit 0
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'exited 0 but printed no line matching'
}

@test "degenerate: a not ok case fails 2.3 even when the tier exits 0" {
    _stub_ci_tools
    _stub just <<'EOF'
if [ "${1:-}" = test ] && [ "${2:-}" = integration ]; then
    printf 'ok 1 preflight: a real ghostty is on PATH\n'
    printf 'not ok 6 #175: the effective command ghostty resolves is an ABSOLUTE path\n'
    exit 0
fi
exit 99
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'reported failing cases'
    assert_output --partial 'not ok 6 #175'
}

# --- Item 2.3: the SET of cases and criteria, not one matching line ----------
# Each case below leaves a GREEN tier (exit 0, no `not ok`) that matches the
# tier's grep pattern, and is still missing what the document publishes.

@test "degenerate: one placeholder ok line per tier fails 2.3 and names every missing case" {
    _stub_ci_tools
    printf 'ok 99 ghostty placeholder\n' >"${INT_BLOCK}"
    printf 'ok 99 ghostty chain placeholder\n' >"${SYS_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'is missing 9 of the 9 case(s) doc/acceptance.md lists for it'
    assert_output --partial 'missing case: preflight: a real ghostty is on PATH and reports its version'
    assert_output --partial 'unexpected case: ghostty placeholder'
    # The system-real tier is never reached: the integration tier is red.
    refute_output --partial '# chain: inbox-ok'
}

@test "degenerate: a subset of the documented system-real criteria fails 2.3 and names the missing ones" {
    _stub_ci_tools
    _write_tier_blocks
    # Every `ok` case still there; only the single-instance evidence thinned
    # out to the two lines that are easiest to fake.
    grep -v '^# single-instance: \(FORWARDED_AFTER_RETURN\|COMMAND_FINISHED\|RUNNING_COMMANDS\)=' \
        "${SYS_BLOCK}" >"${SYS_BLOCK}.tmp"
    mv "${SYS_BLOCK}.tmp" "${SYS_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'printed no line meeting the documented criterion ^# single-instance: FORWARDED_AFTER_RETURN=yes$'
    assert_output --partial 'printed no line meeting the documented criterion ^# single-instance: COMMAND_FINISHED=no$'
    assert_output --partial 'printed no line meeting the documented criterion ^# single-instance: RUNNING_COMMANDS=2$'
}

@test "degenerate: plausible-but-wrong criterion values fail 2.3 (tmux=yes, FORWARDED_STARTED=no, COMMAND_FINISHED=yes)" {
    _stub_ci_tools
    _write_tier_blocks
    sed -i -e 's/tmux=no/tmux=yes/' \
        -e 's/FORWARDED_STARTED=yes/FORWARDED_STARTED=no/' \
        -e 's/COMMAND_FINISHED=no/COMMAND_FINISHED=yes/' "${SYS_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'printed no line meeting the documented criterion ^# chain: inbox-ok fish='
    assert_output --partial 'printed no line meeting the documented criterion ^# single-instance: FORWARDED_STARTED=yes$'
    assert_output --partial 'printed no line meeting the documented criterion ^# single-instance: COMMAND_FINISHED=no$'
}

@test "degenerate: a per-run measurement stays pattern-matched, so a different host, fish, elapsed and delay still pass 2.3" {
    _stub_ci_tools
    _write_tier_blocks
    sed -i -e 's/host=ca83e9d035cd/host=0f1e2d3c4b5a/g' \
        -e 's/fish=4.2.1/fish=3.7.0/g' \
        -e 's/SECOND_ELAPSED=1$/SECOND_ELAPSED=0/' \
        -e 's/FORWARDED_DELAY_MS=319/FORWARDED_DELAY_MS=7/' \
        -e 's/after 45s (budget 45s/after 90s (budget 90s/' "${SYS_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_success
    assert_line '# single-instance: SECOND_ELAPSED=0'
}

@test "degenerate: a SECOND_ELAPSED outside the 0-15 the document publishes fails 2.3" {
    _stub_ci_tools
    _write_tier_blocks
    # The forwarded launch took sixteen minutes to return, which is the exact
    # opposite of the fast return this case exists to observe - and `[0-9]+`
    # matched it happily.
    sed -i -e 's/^# single-instance: SECOND_ELAPSED=1$/# single-instance: SECOND_ELAPSED=999/' \
        "${SYS_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'printed no line meeting the documented criterion ^# single-instance: SECOND_ELAPSED='
}

@test "control: the documented upper bound 15 for SECOND_ELAPSED still passes 2.3" {
    _stub_ci_tools
    _write_tier_blocks
    sed -i -e 's/^# single-instance: SECOND_ELAPSED=1$/# single-instance: SECOND_ELAPSED=15/' \
        "${SYS_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_success
    assert_line '# single-instance: SECOND_ELAPSED=15'
}

@test "degenerate: a documented case reported twice fails 2.3 and names it" {
    _stub_ci_tools
    _write_tier_blocks
    printf 'ok 17 ghostty chain: the managed block pins gtk-single-instance = false (no D-Bus false positive)\n' \
        >>"${SYS_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'reported 1 documented case(s) more than once'
    assert_output --partial 'repeated 2x: ghostty chain: the managed block pins gtk-single-instance = false (no D-Bus false positive)'
}

@test "degenerate: a ghostty case doc/acceptance.md does not list fails 2.3 and names it" {
    _stub_ci_tools
    _write_tier_blocks
    printf 'ok 13 a brand new ghostty case nobody wrote into the document\n' >>"${INT_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'unexpected case: a brand new ghostty case nobody wrote into the document'
}

@test "degenerate: the hang 124 printed before its in-box ready marker fails 2.3" {
    _stub_ci_tools
    _write_tier_blocks
    # Both lines are still there, and the case still says ok - only the
    # order is wrong, which is the difference between "a running in-box
    # command was cut at its budget" and "the window never reached the box".
    sed -i -e '/^# hang-ready: /d' "${SYS_BLOCK}"
    sed -i -e '/^# hang: /a # hang-ready: hang-ready fish=4.2.1 host=ca83e9d035cd' "${SYS_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'printed ^# hang: '
    assert_output --partial 'which the document requires to come first'
}

# --- CLI contract ------------------------------------------------------------

@test "cli: --help exits 0 and documents the exit codes" {
    run "${GATE_SH}" --help
    assert_success
    assert_output --partial 'Usage: gate.sh [ITEM...]'
    assert_output --partial '3 the check cannot run'
}

@test "cli: an unknown option exits 2 and names the option" {
    run "${GATE_SH}" --bogus
    assert_failure 2
    assert_output --partial "gate.sh: unknown option '--bogus' (see --help)"
}

@test "cli: an unknown item exits 2 and names the item" {
    run "${GATE_SH}" 9.9
    assert_failure 2
    assert_output --partial "gate.sh: unknown item '9.9' (see --help)"
}

@test "cli: --list prints the four registered items with their groups" {
    run "${GATE_SH}" --list
    assert_success
    assert_line --partial '2.1  ci  '
    assert_line --partial '2.2  gh  '
    assert_line --partial '2.3  ci  '
    assert_line --partial '2.4  doc '
}
