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

# shellcheck source=test/helper/diagnostics.bash
source "${BATS_TEST_DIRNAME}/../helper/diagnostics.bash"

GATE_SH="${REPO_ROOT}/script/verify/gate.sh"

@test "acceptance doc: bare just test stage count and order match the runner" {
    # Source the real runner in a separate shell; its direct-execution guard
    # leaves HOST_STEPS available without starting any test stages.
    run bash -c 'source "$1"; printf "%s\n" "${HOST_STEPS[@]}"' \
        _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    local -a stages=("${lines[@]}")
    local -a counts=(零 一 二 三 四 五 六 七 八 九 十)
    [ "${#stages[@]}" -gt 0 ]
    [ "${#stages[@]}" -lt "${#counts[@]}" ]
    local count="${counts[${#stages[@]}]}" order="" stage
    for stage in "${stages[@]}"; do
        order+="${order:+、}${stage}"
    done

    run grep -E '^(- \[ \] 2\.|  - \[ \] 2\.1 )' \
        "${REPO_ROOT}/doc/acceptance.md"
    assert_success
    assert_line --partial "2. 自動測試:${count}個階段全綠"
    assert_line --partial "2.1 裸 \`just test\` 跑完${count}個階段(依序為 ${order});"
}

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
    mkdir -p "${COPY}/lib"
    cp "${REPO_ROOT}/lib/guard.sh" "${REPO_ROOT}/lib/log.sh" "${REPO_ROOT}/lib/verify_run.sh" "${REPO_ROOT}/lib/verify_busy_latency.awk" "${COPY}/lib/"
    # CI mode (#833): the job-judging lib and the runner whose HOST_STEPS
    # name the bare `just test` stages.
    if [[ -f "${REPO_ROOT}/lib/verify_ci_gate.sh" ]]; then
        cp "${REPO_ROOT}/lib/verify_ci_gate.sh" "${COPY}/lib/"
    fi
    mkdir -p "${COPY}/script/test" "${COPY}/.github/workflows"
    cp "${REPO_ROOT}/script/test/test.sh" "${COPY}/script/test/test.sh"
    cp "${REPO_ROOT}/.github/workflows/ci.yml" "${COPY}/.github/workflows/ci.yml"
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
ok 38 the ghostty command just box setup writes enters the box directly without starting tmux
ok 39 setup then status: status reports the stored decisions, sources and the ghostty block present, no tmux line
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
    local _marker _ready
    _marker="$(diagnostic_chain_marker 4.2.1 /run/.containerenv 'mnt:[1234]' no ca83e9d035cd)"
    _ready="$(diagnostic_ready_marker 4.2.1 ca83e9d035cd)"
    {
        printf '%s\n' '# chain-cold: changing progress updates=42; setup command entered fish in dev'
        printf '%s\n' 'ok 5 ghostty chain cold start (#434): setup-written command reports continuous first-init progress and enters fish'
        printf '%s\n' 'ok 12 ghostty chain: the managed block pins gtk-single-instance = false (no D-Bus false positive)'
        diagnostic_lines chain "${_marker}" >/dev/null
        diagnostic_in_box chain 'mnt:[1234]' ca83e9d035cd >/dev/null
        printf '%s\n' "ok 13 ghostty chain: a real window runs the managed block's command and leaves a marker INSIDE the box (fish, the box's mount namespace, no tmux)"
        diagnostic_lines hang-ready "${_ready}" >/dev/null
        diagnostic_hang 45 45 124 >/dev/null
        printf '%s\n' 'ok 14 ghostty chain: a command that has STARTED inside the box and never ends FAILS within its budget instead of hanging'
        diagnostic_lines single-instance PRIMARY=up SECOND_RC=0 SECOND_ELAPSED=1 \
            STARTED_AT_RETURN=1 FORWARDED_STARTED=yes FORWARDED_AFTER_RETURN=yes \
            FORWARDED_DELAY_MS=319 RUNNING_COMMANDS=2 PRIMARY_WRAPPER_ALIVE=yes \
            COMMAND_FINISHED=no >/dev/null
        printf '%s\n' 'ok 15 ghostty chain: with gtk-single-instance on, a forwarded launch exits 0 while the command it asked for has not begun yet (the false positive the guard prevents)'
        diagnostic_lines chain-desktop-path "${_marker}" >/dev/null
        diagnostic_in_box chain-desktop-path 'mnt:[1234]' ca83e9d035cd >/dev/null
        printf '%s\n' "ok 16 ghostty chain (#175): the absolute distrobox path just box setup writes enters the box from a desktop session's PATH"
    } 3>&1
}

# Write both blocks in their documented (passing) form. INT_BLOCK and
# SYS_BLOCK are the files a case mutates before stubbing `just`.
_write_tier_blocks() {
    _integration_block >"${INT_BLOCK}"
    _system_real_block >"${SYS_BLOCK}"
}

# The report formatter annotates only TAP case lines, never diagnostics.
_write_timed_tier_blocks() {
    _write_tier_blocks
    local _file
    for _file in "${INT_BLOCK}" "${SYS_BLOCK}"; do
        sed -i '/^ok [0-9][0-9]* /s/$/ # in 211 ms/' "${_file}"
    done
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
    assert_line "[INFO] gate.sh: ${COPY}/doc/evidence/negative/empty-red-block.md is missing - item 2.4 cannot be checked here"
    refute_output --partial '[UNAVAILABLE]'
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
    assert_line '[UNAVAILABLE] gate.sh: awk not found on PATH'
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

# --- Item 2.1: the seven-stage run is judged by its own status ------------------

# Generate real bats-assert diagnostics instead of assuming their format.
_stub_busy_latency() {
    local _fixture="${BATS_TEST_TMPDIR}/latency.bats"
    printf 'load "%s/test/helper/common"\n' "${REPO_ROOT}" >"${_fixture}"
    sed -n '/^@test "real engine: bench.sh /p' \
        "${REPO_ROOT}/test/system/real_engine_spec.bats" | while IFS= read -r _test; do
        printf '%s\n' "${_test}" >>"${_fixture}"
        cat >>"${_fixture}" <<'EOF'
    run bash -c 'if [[ ${BUSY_MULTILINE:-0} == 1 ]]; then echo "[INFO] waiting for a quiet host"; fi; echo "[ERROR] host too busy to measure (inconclusive): /proc/pressure/cpu some avg10=3.00 for 60s; loadavg=4; re-run when idle" >&2; exit 3'
    if [[ "${BATS_TEST_DESCRIPTION}" == *'exits 0 ('* ]]; then
        assert_success
    else
        assert_failure 1
    fi
}
EOF
    done
    _stub just <<EOF
printf '[ci] acceptance bats OK\n[ci] Running system-real bats (test/system/real_engine_spec.bats)\n' >&2
bats --formatter tap '${_fixture}'
rc=\$?
printf '[ci] ERROR: system-real bats failed\n' >&2
printf '%s\n' '[system-real] cleanup: containers left in the nested daemon: 0' \
    '[system-real] stopping nested dockerd (pid 123)' \
    '[system-real] --- dockerd log (tail): /var/log/worktool-dockerd.log' \
    'time=2026-11-03 level=info msg=shutdown' \
    '[system-real] --- end of dockerd log' >&2
exit "\${rc}"
EOF
}

@test "2.1: only busy latency failures are inconclusive, never PASS" {
    _stub_ci_tools
    _stub_busy_latency
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.1
    assert_failure 3
    assert_output --partial '未判定、請在閒置時重跑'
    refute_output --partial 'PASSED'
    refute_output --partial 'FAILED'
}

@test "2.1: busy verdict survives stderr relayed after all stdout" {
    _stub_ci_tools
    _stub_busy_latency
    local _transcript="${BATS_TEST_TMPDIR}/busy.tap" _stderr="${BATS_TEST_TMPDIR}/runner.log" _rc=0
    "${BIN}/just" >"${_transcript}" 2>"${_stderr}" || _rc=$?
    [[ "${_rc}" -eq 1 ]]
    _stub just <<EOF
cat '${_transcript}'
cat '${_stderr}' >&2
exit 1
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.1
    assert_failure 3
    assert_output --partial '未判定、請在閒置時重跑'
    refute_output --partial 'FAILED'

    _stub just <<EOF
cat '${_stderr}' >&2
cat '${_transcript}'
exit 1
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.1
    assert_failure 3
    assert_output --partial '未判定、請在閒置時重跑'
    refute_output --partial 'FAILED'
}

@test "2.1: mixed failures and unreliable latency evidence stay failed" {
    _stub_ci_tools
    _stub_busy_latency
    local _transcript="${BATS_TEST_TMPDIR}/busy.tap" _stderr="${BATS_TEST_TMPDIR}/runner.log" _rc=0 _mode
    "${BIN}/just" >"${_transcript}" 2>"${_stderr}" || _rc=$?
    [[ "${_rc}" -eq 1 ]]
    for _mode in mixed infrastructure missing-status missing-busy truncated; do
        cp "${_transcript}" "${SYS_BLOCK}"
        case "${_mode}" in
            mixed)
                sed -i 's/^1\.\.2$/1..3/' "${SYS_BLOCK}"
                printf 'not ok 3 real engine: fish is broken\n' >>"${SYS_BLOCK}" ;;
            infrastructure)
                printf '[system-real] ERROR: runner cleanup failed\n' >>"${SYS_BLOCK}" ;;
            missing-status)
                sed -i '/^# status : 3$/d; /^# actual   : 3$/d' "${SYS_BLOCK}" ;;
            missing-busy)
                sed -i '/host too busy/d' "${SYS_BLOCK}" ;;
            truncated)
                sed -i 's/^1\.\.2$/1..3/' "${SYS_BLOCK}" ;;
        esac
        _stub just <<EOF
cat '${SYS_BLOCK}'
cat '${_stderr}' >&2
exit 1
EOF
        PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.1
        assert_failure 1
        refute_output --partial '未判定、請在閒置時重跑'
    done
}

@test "2.1: multiline bench diagnostics preserve the inconclusive verdict" {
    _stub_ci_tools
    _stub_busy_latency
    BUSY_MULTILINE=1 PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.1
    assert_failure 3
    assert_output --partial '未判定、請在閒置時重跑'
}

@test "2.1: preserves stdout and stderr for passing and busy latency runs" {
    bats_require_minimum_version 1.5.0
    local stderr=""
    _stub_ci_tools
    _stub just <<'EOF'
printf '1..1\nok 1 the gate is green\n'
printf '[ci] system-real bats OK\n' >&2
EOF
    PATH="${BIN}:${PATH}" run --separate-stderr "${COPY_GATE}" 2.1
    assert_success
    assert_output $'1..1\nok 1 the gate is green'
    [[ "${stderr}" == *'[ci] system-real bats OK'* ]]

    _stub_busy_latency
    PATH="${BIN}:${PATH}" run --separate-stderr "${COPY_GATE}" 2.1
    assert_failure 3
    assert_output --partial 'not ok 1 real engine: bench.sh'
    refute_output --partial '[ci] ERROR:'
    refute_output --partial '[system-real]'
    [[ "${stderr}" == *'[ci] ERROR: system-real bats failed'* ]]
    [[ "${stderr}" == *'[system-real] stopping nested dockerd (pid 123)'* ]]
    [[ "${stderr}" == *'未判定、請在閒置時重跑'* ]]
}

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

@test "false-pass guard: the seven-stage just test run exiting 1 fails 2.1" {
    _stub_ci_tools
    _stub just <<'EOF'
printf '[ci] ShellCheck OK\n'
printf '[ci]   required specs OK (331 case(s) declared by 15 file(s))\n'
printf '[ci] system-real bats OK\n'
exit 1
EOF
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.1
    assert_failure 1
    assert_output --partial 'exited 1 - the seven-stage gate is not green'
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

@test "control: item 2.3 accepts the real integration case names and its fixture matches that set" {
    _stub_ci_tools
    _write_tier_blocks
    local _fixture_names="${BATS_TEST_TMPDIR}/fixture.names"
    local _real_names="${BATS_TEST_TMPDIR}/real.names"
    sed -n 's/^ok [0-9][0-9]* //p' "${INT_BLOCK}" | sort >"${_fixture_names}"
    # Read declarations, without executing integration tests in the unit tier.
    # Feed all names through the CLI so its selection and INTEGRATION_CASES
    # must agree with the real suite, independently of the hand-written fixture.
    sed -n 's/^@test "\(.*\)" {$/\1/p' "${REPO_ROOT}"/test/integration/*.bats \
        | awk '{ print "ok " NR " " $0 }' >"${INT_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_success
    grep '^ok .*ghostty' "${INT_BLOCK}" | sed 's/^ok [0-9][0-9]* //' | sort >"${_real_names}"
    run diff -u "${_real_names}" "${_fixture_names}"
    assert_success
}

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
    assert_output --partial 'is missing 10 of the 10 case(s) doc/acceptance.md lists for it'
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

@test "timed TAP: local integration and system-real exact sets and hang order pass" {
    _stub_ci_tools
    _write_timed_tier_blocks
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_success
    assert_line 'ok 14 ghostty chain: a command that has STARTED inside the box and never ends FAILS within its budget instead of hanging # in 211 ms'
    assert_line '# single-instance: COMMAND_FINISHED=no'
}

@test "timed TAP: a genuinely missing case remains missing" {
    _stub_ci_tools
    _write_timed_tier_blocks
    sed -i '1d' "${INT_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'missing case: the ghostty command just box setup writes enters the box directly without starting tmux'
}

@test "timed TAP: duplicate cases with different timings remain duplicates" {
    _stub_ci_tools
    _write_timed_tier_blocks
    printf 'ok 99 ghostty chain: the managed block pins gtk-single-instance = false (no D-Bus false positive) # in 999 ms\n' >>"${SYS_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'repeated 2x: ghostty chain: the managed block pins gtk-single-instance = false (no D-Bus false positive)'
}

@test "timed TAP: a wrong case name stays unexpected" {
    _stub_ci_tools
    _write_timed_tier_blocks
    sed -i '1s/starting tmux/starting something-else/' "${INT_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'unexpected case: the ghostty command just box setup writes enters the box directly without starting something-else'
}

@test "timed TAP: skipped or failed cases and nonzero tiers never pass" {
    local _mode
    _stub_ci_tools
    for _mode in skip failed nonzero; do
        _write_timed_tier_blocks
        case "${_mode}" in
            skip) sed -i '1s/ # in/ # skip unavailable # in/' "${INT_BLOCK}" ;;
            failed) printf 'not ok 99 ghostty failed # in 211 ms\n' >>"${INT_BLOCK}" ;;
        esac
        if [[ "${_mode}" == nonzero ]]; then
            _stub_just_blocks 1 0
        else
            _stub_just_blocks 0 0
        fi
        PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
        assert_failure 1
        case "${_mode}" in
            skip) assert_output --partial '# skip unavailable' ;;
            failed) assert_output --partial 'reported failing cases' ;;
            nonzero) assert_output --partial 'exited 1 - what it printed does not count' ;;
        esac
    done
}

@test "timed TAP: invalid or nonterminal timing text never rewrites a name" {
    local _suffix
    _stub_ci_tools
    for _suffix in ' # in -1 ms' ' # in 1.5 ms' ' # in 2 ms trailing' ' # in 1 ms # in 2 ms'; do
        _write_tier_blocks
        sed -i "1s/\$/${_suffix}/" "${INT_BLOCK}"
        _stub_just_blocks 0 0
        PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
        assert_failure 1
        assert_output --partial 'unexpected case:'
    done
}

@test "timed TAP: diagnostic criteria keep their exact values and cannot borrow case timing" {
    _stub_ci_tools
    _write_timed_tier_blocks
    sed -i 's/^# single-instance: COMMAND_FINISHED=no$/& # in 211 ms/' "${SYS_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'printed no line meeting the documented criterion ^# single-instance: COMMAND_FINISHED=no$'
}

@test "timed TAP: reversed ready and hang markers still fail the documented order" {
    _stub_ci_tools
    _write_timed_tier_blocks
    sed -i '/^# hang-ready: /d; /^# hang: /a # hang-ready: hang-ready fish=4.2.1 host=ca83e9d035cd' "${SYS_BLOCK}"
    _stub_just_blocks 0 0
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'which the document requires to come first'
    refute_output --partial 'so the documented order cannot hold'
}

# --- CLI contract ------------------------------------------------------------

@test "cli: --help exits 0 and documents the exit codes" {
    run "${GATE_SH}" --help
    assert_success
    assert_output --partial 'Usage: gate.sh [ITEM...]'
    assert_output --partial '3 the check cannot run'
    assert_output --partial 'the latency gate is inconclusive (host busy)'
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

@test "single source: system-real cases match declarations, gate selection and document" {
    run grep -F "integration 與 system-real 的 \`ok\` 案例分別以 \`INTEGRATION_CASES\` 與 \`SYSTEM_REAL_CASES\` 清單為準" \
        "${REPO_ROOT}/doc/acceptance.md"
    assert_success
    _stub_ci_tools
    _write_tier_blocks
    local _real="${BATS_TEST_TMPDIR}/real.names" _fixture="${BATS_TEST_TMPDIR}/fixture.names"
    sed -n 's/^@test "\(ghostty chain.*\)" {$/\1/p' \
        "${REPO_ROOT}"/test/system/*.bats | sort >"${_real}"
    sed -n 's/^ok [0-9][0-9]* //p' "${SYS_BLOCK}" | sort >"${_fixture}"
    run diff -u "${_real}" "${_fixture}"
    assert_success
    sed -n 's/^      ok [0-9][0-9]* \(ghostty chain.*\)$/\1/p' \
        "${REPO_ROOT}/doc/acceptance.md" | sort >"${_fixture}"
    run diff -u "${_real}" "${_fixture}"
    assert_success
    _stub_just_blocks
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_success
}

@test "single source: diagnostic criteria accept producer output and reject a broken judgement via CLI" {
    _stub_ci_tools
    _write_tier_blocks
    _stub_just_blocks
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_success
    sed -i 's/COMMAND_FINISHED=no/COMMAND_FINISHED=yes/' "${SYS_BLOCK}"
    PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    refute_output --partial '2.3 PASS'
}

@test "single source: chain diagnostics use the shared producer without reading spec code" {
    # Public evidence formatter, also used by the real system suite.
    # shellcheck source=test/helper/diagnostics.bash
    source "${REPO_ROOT}/test/helper/diagnostics.bash"
    local _out _line
    _system_real_block >"${SYS_BLOCK}"
    _out="$( {
        diagnostic_lines chain "$(diagnostic_chain_marker 4.2.1 /run/.containerenv 'mnt:[1234]' no ca83e9d035cd)"
        diagnostic_in_box chain 'mnt:[1234]' ca83e9d035cd
        diagnostic_lines hang-ready "$(diagnostic_ready_marker 4.2.1 ca83e9d035cd)"
        diagnostic_hang 45 45 124
    } 3>&1 >/dev/null)"
    while IFS= read -r _line; do
        run grep -Fx "${_line}" "${SYS_BLOCK}"
        assert_success
    done <<<"${_out}"
}

@test "single source: every documented TAP case exists in the real suites" {
    local _names="${BATS_TEST_TMPDIR}/all.names" _line
    find "${REPO_ROOT}/test" -name '*_spec.bats' -exec \
        sed -n 's/^@test "\(.*\)" {$/\1/p' {} + >"${_names}"
    while IFS= read -r _line; do
        [[ "${_line}" == '...' ]] && continue
        printf '# documented case: %s\n' "${_line}" >&3
        run grep -Fx "${_line}" "${_names}"
        assert_success
    done < <(sed -n '/^### 自動測試驗收/,/^- \[ \] 3\. 進盒設定:/s/^ *ok [0-9][0-9]* \(.*\)$/\1/p' "${REPO_ROOT}/doc/acceptance.md")
}

_m2_runner_doc_valid() {
    local _section _source="[script/test/test.sh](../script/test/test.sh)"
    _section="$(sed -n '/^- \[ \] 1\. 自動測試:/,/^- \[ \] 2\. 交付自檢/p' "$1")"
    [[ "${_section}" == *"${_source}"* ]] || return 1
    [[ "${_section}" == *'[test/system/real_engine_spec.bats](../test/system/real_engine_spec.bats)'* ]] || return 1
    [[ "${_section}" == *'skip 依 runner 政策判定'* ]] || return 1
    [[ "${_section}" == *'host unchanged'* ]] || return 1
    if grep -Eq '\[ci\]|\[system-real\]|required specs OK|^[[:space:]]*1\.\.[0-9]+|[0-9]+ 個必要 spec' <<<"${_section}"; then
        return 1
    fi
}

@test "M2 runner acceptance uses live sources rather than output snapshots" {
    run _m2_runner_doc_valid "${REPO_ROOT}/doc/acceptance.md"
    assert_success
}

@test "M2 runner documentation guard rejects snapshots and missing source" {
    local _doc="${BATS_TEST_TMPDIR}/acceptance.md"
    sed '/^  - \[ \] 1\.1 lint:/a\      [ci] required specs OK (135 case(s))' "${REPO_ROOT}/doc/acceptance.md" >"${_doc}"
    run _m2_runner_doc_valid "${_doc}"
    assert_failure
    sed 's|test/system/real_engine_spec.bats|test/system/obsolete.bats|g' "${REPO_ROOT}/doc/acceptance.md" >"${_doc}"
    run _m2_runner_doc_valid "${_doc}"
    assert_failure
}

@test "single source: documented chain diagnostics equal the source-guarded fixture" {
    local _fixture="${BATS_TEST_TMPDIR}/fixture.diag" _doc="${BATS_TEST_TMPDIR}/doc.diag"
    _system_real_block | grep '^#' >"${_fixture}"
    sed -n 's/^      \(# \(chain[^:]*\|hang[^:]*\|single-instance\): .*\)$/\1/p' \
        "${REPO_ROOT}/doc/acceptance.md" >"${_doc}"
    run diff -u "${_fixture}" "${_doc}"
    assert_success
}

@test "timeout cleanup: item 2.1 kills a TERM-ignoring descendant before returning" {
    _stub_ci_tools
    _stub just <<'EOF'
bash -c 'trap "" TERM; echo "$BASHPID" >"$ORPHAN_PID"; sleep 3; touch "$ORPHAN_MARKER"' >/dev/null 2>&1 &
wait
EOF
    local pid_file="${BATS_TEST_TMPDIR}/orphan.pid" marker="${BATS_TEST_TMPDIR}/late"
    ORPHAN_PID="${pid_file}" ORPHAN_MARKER="${marker}" GATE_TIMEOUT=0.2 PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.1
    assert_failure 1
    assert_output --partial 'did not finish within 0.2s (timeout)'
    local pid
    pid="$(cat "${pid_file}")"
    local alive=0
    if kill -0 "${pid}" 2>/dev/null && ! grep -qE '^[0-9]+ \([^)]*\) Z ' "/proc/${pid}/stat"; then
        alive=1
        kill -KILL "${pid}"
    fi
    [ "${alive}" -eq 0 ]
    [ ! -e "${marker}" ]
}

@test "timeout cleanup: item 2.3 kills a TERM-ignoring descendant before returning" {
    _stub_ci_tools
    _stub just <<'EOF'
bash -c 'trap "" TERM; echo "$BASHPID" >"$ORPHAN_PID"; sleep 3; touch "$ORPHAN_MARKER"' >/dev/null 2>&1 &
wait
EOF
    local pid_file="${BATS_TEST_TMPDIR}/orphan.pid" marker="${BATS_TEST_TMPDIR}/late"
    ORPHAN_PID="${pid_file}" ORPHAN_MARKER="${marker}" GATE_TIMEOUT=0.2 PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 1
    assert_output --partial 'did not finish within 0.2s (timeout)'
    local pid
    pid="$(cat "${pid_file}")"
    local alive=0
    if kill -0 "${pid}" 2>/dev/null && ! grep -qE '^[0-9]+ \([^)]*\) Z ' "/proc/${pid}/stat"; then
        alive=1
        kill -KILL "${pid}"
    fi
    [ "${alive}" -eq 0 ]
    [ ! -e "${marker}" ]
}

@test "timeout cleanup: removes only containers labeled by this run" {
    _stub docker <<'EOF'
printf '%s\n' "$*" >>"$CLEANUP_CALLS"
if [[ "$1" == ps ]]; then
    [[ "$*" == *"label=worktool.verify-run=$(cat "$RUN_ID")"* ]] || exit 1
    echo owned-container
elif [[ "$1" == rm ]]; then
    [[ "$*" == 'rm -f -v owned-container' ]] || exit 1
    touch "$CONTAINER_STOPPED"
fi
EOF
    _stub just <<'EOF'
printf '%s' "${WORKTOOL_TEST_RUN_ID:-}" >"$RUN_ID"
sleep 5
EOF
    local id="${BATS_TEST_TMPDIR}/id" stopped="${BATS_TEST_TMPDIR}/stopped"
    local calls="${BATS_TEST_TMPDIR}/cleanup"
    RUN_ID="${id}" CONTAINER_STOPPED="${stopped}" CLEANUP_CALLS="${calls}" \
        GATE_TIMEOUT=0.2 PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.1
    assert_failure 1
    assert_output --partial 'did not finish within 0.2s (timeout)'
    [ -s "${id}" ]
    [ -e "${stopped}" ]
    run cat "${calls}"
    assert_line 'rm -f -v owned-container'
    refute_output --partial prune
}

@test "#714: system-real selection removes only the dead chain-host alternative" {
    run sed -n '/^SYSTEM_REAL_PATTERN=/p' "${GATE_SH}"
    assert_success
    assert_output "SYSTEM_REAL_PATTERN='^# (chain|hang|single-instance)|^ok .*ghostty chain|^not ok'"
}

# --- CI mode (#833): 2.1 and 2.3 judge the gate jobs of their own run --------
# verify-all names its run; gate.sh then reads that run's jobs (and, for 2.3,
# their logs) through `gh api` instead of running `just test` again. `just`
# is stubbed to fail loudly so a CI-mode case that falls back to running the
# tiers turns red.

CI_SHA=0123456789abcdef0123456789abcdef01234567
CI_RUN=4242

# The bare `just test` stages, read the way gate.sh reads them.
_ci_steps() {
    bash -c 'source "$1"; printf "%s\n" "${HOST_STEPS[@]}"' _ "${REPO_ROOT}/script/test/test.sh"
}

# Write the job list of a fully green run: every stage on both runners.
# Integration jobs get ids 101 / 102, system-real 201 / 202 (amd64 / arm).
_ci_jobs_green() {
    local _out="$1" _step _runner _name _id _i=0
    : >"${_out}"
    for _runner in ubuntu-latest ubuntu-24.04-arm; do
        _i=$(( _i + 1 ))
        while IFS= read -r _step; do
            case "${_step}" in
                lint) _name="lint (${_runner})" ;;
                *)    _name="test-${_step} (${_runner})" ;;
            esac
            case "${_step}" in
                integration) _id="10${_i}" ;;
                system-real) _id="20${_i}" ;;
                *)           _id="3${_i}0" ;;
            esac
            printf '%s\t%s\t%s\tcompleted\tsuccess\t%s\n' "${_name}" "${CI_SHA}" "${CI_RUN}" "${_id}" >>"${_out}"
        done < <(_ci_steps)
    done
    if [[ "${2:-}" != legacy ]]; then
        grep -vE '^(lint|test-unit|test-system|test-acceptance) \(' "${_out}" >"${_out}.new"
        {
            printf 'test-unit-verdict\t%s\t%s\tcompleted\tsuccess\t900\n' "${CI_SHA}" "${CI_RUN}"
            printf 'lint-system-acceptance (ubuntu-latest)\t%s\t%s\tcompleted\tsuccess\t901\n' "${CI_SHA}" "${CI_RUN}"
            printf 'lint-system-acceptance (ubuntu-24.04-arm)\t%s\t%s\tcompleted\tsuccess\t902\n' "${CI_SHA}" "${CI_RUN}"
        } >>"${_out}.new"
        mv "${_out}.new" "${_out}"
    fi
}

# A gh that serves the job list in $1 and, per job id, the timestamped log
# made from INT_BLOCK (ids 101 / 102) or SYS_BLOCK (201 / 202). $2 = the
# exit status of every gh call (default 0).
_stub_gh_ci() {
    local _jobs="$1" _rc="${2:-0}" _logs="${BATS_TEST_TMPDIR}/ci-logs"
    mkdir -p "${_logs}"
    sed 's/^/2026-11-10T06:00:00.0000000Z /' "${INT_BLOCK}" >"${_logs}/101"
    cp "${_logs}/101" "${_logs}/102"
    sed 's/^/2026-11-10T06:00:00.0000000Z /' "${SYS_BLOCK}" >"${_logs}/201"
    cp "${_logs}/201" "${_logs}/202"
    _stub gh <<EOF
printf 'gh %s\n' "\$*" >>$(printf '%q' "${BATS_TEST_TMPDIR}/gh-calls")
[[ ${_rc} -eq 0 ]] || exit ${_rc}
for _a in "\$@"; do
    case "\${_a}" in
        repos/*/actions/runs/${CI_RUN}/jobs*) cat -- $(printf '%q' "${_jobs}"); exit 0 ;;
        repos/*/actions/jobs/*/logs) _id="\${_a#*/actions/jobs/}"; cat -- $(printf '%q' "${_logs}")/"\${_id%/logs}"; exit 0 ;;
    esac
done
printf 'fake gh: unexpected: %s\n' "\$*" >&2
exit 99
EOF
}

_stub_just_must_not_run() {
    _stub just <<'EOF'
printf 'fake just: CI mode must not run just: %s\n' "$*" >&2
exit 99
EOF
}

# Run the copy's gate.sh in CI mode for item $1.
_run_ci_item() {
    WORKTOOL_VERIFY_GATE_RUN="${CI_RUN}" WORKTOOL_VERIFY_GATE_SHA="${CI_SHA}" \
        WORKTOOL_VERIFY_GATE_REPO=owner/repo PATH="${BIN}:${PATH}" run "${COPY_GATE}" "$1"
}

@test "CI mode 2.1: every stage of bare just test green on both runners passes without running just" {
    _write_tier_blocks
    _ci_jobs_green "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_gh_ci "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_just_must_not_run
    _run_ci_item 2.1
    assert_success
    refute_output --partial 'fake just'
    # Three matrix legs and real-engine on both runners, plus unit verdict.
    assert_equal "$(printf '%s\n' "${output}" | grep -c '^reused: ')" 9
    assert_line "reused: test-system-real (ubuntu-24.04-arm) success run=${CI_RUN} job=202"
    assert_line "reused: lint-system-acceptance (ubuntu-latest) success run=${CI_RUN} job=901"
}

@test "CI mode 2.1: the stage set comes from HOST_STEPS, so a stage without its job fails and is named" {
    _write_tier_blocks
    _ci_jobs_green "${BATS_TEST_TMPDIR}/all.tsv"
    grep -v '^test-matrix (ubuntu-24.04-arm)' "${BATS_TEST_TMPDIR}/all.tsv" >"${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_gh_ci "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_just_must_not_run
    _run_ci_item 2.1
    assert_failure 1
    assert_output --partial 'job "test-matrix (ubuntu-24.04-arm)" appears 0 times'
}

@test "CI mode 2.1: a failed, skipped or other-sha job fails the item" {
    _write_tier_blocks
    _ci_jobs_green "${BATS_TEST_TMPDIR}/all.tsv"
    local _mut
    for _mut in 's/^\(test-unit-verdict\t.*\t\)success\t/\1failure\t/' \
                's/^\(lint-system-acceptance (ubuntu-24.04-arm)\t.*\t\)success\t/\1skipped\t/' \
                "s/^\\(lint-system-acceptance (ubuntu-latest)\\t\\)${CI_SHA}/\\1fedcba9876543210fedcba9876543210fedcba98/"; do
        sed "${_mut}" "${BATS_TEST_TMPDIR}/all.tsv" >"${BATS_TEST_TMPDIR}/jobs.tsv"
        _stub_gh_ci "${BATS_TEST_TMPDIR}/jobs.tsv"
        _stub_just_must_not_run
        _run_ci_item 2.1
        assert_failure 1
        assert_output --partial 'item 2.1 FAILED'
    done
}

@test "CI mode 2.1: a job query that fails fails the item (fail closed)" {
    _write_tier_blocks
    _ci_jobs_green "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_gh_ci "${BATS_TEST_TMPDIR}/jobs.tsv" 1
    _stub_just_must_not_run
    _run_ci_item 2.1
    assert_failure 1
    refute_output --partial 'reused: '
}

@test "CI mode: a partial request is unavailable (3) and never falls back to running the tiers" {
    _stub_just_must_not_run
    _stub_gh
    WORKTOOL_VERIFY_GATE_RUN="${CI_RUN}" PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.1
    assert_failure 3
    refute_output --partial 'fake just'
    WORKTOOL_VERIFY_GATE_RUN="${CI_RUN}" PATH="${BIN}:${PATH}" run "${COPY_GATE}" 2.3
    assert_failure 3
    refute_output --partial 'fake just'
}

@test "CI mode 2.3: green integration and system-real jobs whose logs carry the documented blocks pass" {
    _write_tier_blocks
    _ci_jobs_green "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_gh_ci "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_just_must_not_run
    _run_ci_item 2.3
    assert_success
    assert_line "reused: test-integration (ubuntu-latest) success run=${CI_RUN} job=101"
    assert_line "reused: test-system-real (ubuntu-24.04-arm) success run=${CI_RUN} job=202"
    assert_line 'ok 1 preflight: a real ghostty is on PATH and reports its version'
    assert_line '# single-instance: COMMAND_FINISHED=no'
    # Both runners' logs were read.
    run cat "${BATS_TEST_TMPDIR}/gh-calls"
    assert_output --partial 'actions/jobs/101/logs'
    assert_output --partial 'actions/jobs/102/logs'
    assert_output --partial 'actions/jobs/201/logs'
    assert_output --partial 'actions/jobs/202/logs'
}

@test "CI mode 2.3: mixed timed and untimed case names match the same exact documented set" {
    _write_tier_blocks
    sed -i '1s/$/ # in 4234 ms/; 2s/$/ # in 211 ms/' "${INT_BLOCK}"
    _ci_jobs_green "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_gh_ci "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_just_must_not_run
    _run_ci_item 2.3
    assert_success
    assert_line 'ok 38 the ghostty command just box setup writes enters the box directly without starting tmux # in 4234 ms'
    refute_output --partial 'missing case:'
    refute_output --partial 'unexpected case:'
}

@test "CI mode 2.3: the real JUnit formatter supplies accepted timing metadata" {
    _write_tier_blocks
    local _spec="${BATS_TEST_TMPDIR}/producer.bats" _report="${BATS_TEST_TMPDIR}/producer-report"
    cat >"${_spec}" <<'EOF'
@test "the ghostty command just box setup writes enters the box directly without starting tmux" { :; }
@test "setup then status: status reports the stored decisions, sources and the ghostty block present, no tmux line" { :; }
EOF
    mkdir -p "${_report}"
    run bats --formatter tap --report-formatter junit --output "${_report}" "${_spec}"
    assert_success
    assert_line --regexp '^ok 1 .* # in [0-9]+ ms$'
    local _actual="${output}"
    tail -n +3 "${INT_BLOCK}" >"${INT_BLOCK}.rest"
    printf '%s\n' "${_actual}" >"${INT_BLOCK}"
    cat "${INT_BLOCK}.rest" >>"${INT_BLOCK}"
    _ci_jobs_green "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_gh_ci "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_just_must_not_run
    _run_ci_item 2.3
    assert_success
    assert_line --regexp '^ok 1 .* # in [0-9]+ ms$'
}

@test "CI mode 2.3: a cancelled system-real job fails the item before any log counts" {
    _write_tier_blocks
    _ci_jobs_green "${BATS_TEST_TMPDIR}/all.tsv"
    sed 's/^\(test-system-real (ubuntu-24.04-arm)\t.*\t\)success\t/\1cancelled\t/' \
        "${BATS_TEST_TMPDIR}/all.tsv" >"${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_gh_ci "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_just_must_not_run
    _run_ci_item 2.3
    assert_failure 1
    assert_output --partial 'concluded cancelled, not success'
}

@test "CI mode 2.3: a green job whose log lacks a documented case still fails (the block is judged too)" {
    _write_tier_blocks
    grep -v 'gtk-single-instance = false' "${SYS_BLOCK}" >"${SYS_BLOCK}.new"
    mv "${SYS_BLOCK}.new" "${SYS_BLOCK}"
    _ci_jobs_green "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_gh_ci "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_just_must_not_run
    _run_ci_item 2.3
    assert_failure 1
    assert_output --partial 'gtk-single-instance = false'
}

@test "CI mode 2.3: a green job whose log carries a not ok line fails" {
    _write_tier_blocks
    printf 'not ok 99 something broke\n' >>"${INT_BLOCK}"
    _ci_jobs_green "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_gh_ci "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_just_must_not_run
    _run_ci_item 2.3
    assert_failure 1
    assert_output --partial 'not ok 99 something broke'
}

@test "CI mode 2.1: after main's job renames the old per-tier names no longer count (#833, audit F8)" {
    _write_tier_blocks
    # main's shape: lint, system and acceptance on one leg, unit as shards
    # with a union verdict.
    sed -i -e 's/^        gate: \[.*\]$/        gate: [lint-system-acceptance, test-matrix, test-integration]/' \
        "${COPY}/.github/workflows/ci.yml"
    awk '
        /^          - gate: lint$/ { print "          - gate: lint-system-acceptance"; getline; print "            tier: lint system acceptance"; next }
        /^          - gate: test-(unit|system|acceptance)$/ { getline; next }
        { print }
        /^jobs:$/ { print "  test-unit-verdict:"; print "    name: test-unit-verdict" }
    ' "${COPY}/.github/workflows/ci.yml" >"${COPY}/ci.new"
    mv "${COPY}/ci.new" "${COPY}/.github/workflows/ci.yml"
    # The old names, all green, are not evidence any more.
    _ci_jobs_green "${BATS_TEST_TMPDIR}/jobs.tsv" legacy
    _stub_gh_ci "${BATS_TEST_TMPDIR}/jobs.tsv"
    _stub_just_must_not_run
    _run_ci_item 2.1
    assert_failure 1
    assert_output --partial 'job "lint-system-acceptance (ubuntu-latest)" appears 0 times'
    assert_output --partial 'job "test-unit-verdict" appears 0 times'
    # The new names, green, are.
    {
        grep -vE '^(lint|test-unit|test-system|test-acceptance) \(' "${BATS_TEST_TMPDIR}/jobs.tsv"
        printf 'test-unit-verdict\t%s\t%s\tcompleted\tsuccess\t900\n' "${CI_SHA}" "${CI_RUN}"
        printf 'lint-system-acceptance (ubuntu-latest)\t%s\t%s\tcompleted\tsuccess\t901\n' "${CI_SHA}" "${CI_RUN}"
        printf 'lint-system-acceptance (ubuntu-24.04-arm)\t%s\t%s\tcompleted\tsuccess\t902\n' "${CI_SHA}" "${CI_RUN}"
    } >"${BATS_TEST_TMPDIR}/new.tsv"
    _stub_gh_ci "${BATS_TEST_TMPDIR}/new.tsv"
    _run_ci_item 2.1
    assert_success
    assert_line "reused: test-unit-verdict success run=${CI_RUN} job=900"
}
