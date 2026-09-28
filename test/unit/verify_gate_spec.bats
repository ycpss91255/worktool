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
# EXIST (doc/evidence/tdd.sh is the thing that would use it, and every 2.2
# case here stubs that script).
_stub_gh() {
    _stub gh <<'EOF'
printf 'fake gh: must not be called: gh %s\n' "$*" >&2
exit 99
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

# The integration and system-real lines item 2.3 publishes, as a `just`
# stub would print them. $1 is the exit status of the integration tier,
# $2 of the system-real tier (both default 0).
_stub_just_tiers() {
    local _int_rc="${1:-0}" _sys_rc="${2:-0}"
    {
        cat <<EOF
if [ "\${1:-}" = test ] && [ "\${2:-}" = integration ]; then
    printf 'ok 1 preflight: a real ghostty is on PATH and reports its version\n'
    printf 'ok 6 #175: the effective command ghostty resolves is an ABSOLUTE distrobox path\n'
    printf 'ok 12 +validate-config refuses a config ghostty cannot parse\n'
    exit ${_int_rc}
fi
if [ "\${1:-}" = test ] && [ "\${2:-}" = system-real ]; then
    printf '# chain: inbox-ok fish=4.2.1 tmux=yes host=ca83e9d035cd\n'
    printf 'ok 13 ghostty chain: a real window runs the managed block command\n'
    exit ${_sys_rc}
fi
printf 'fake just: unexpected: %s\n' "\$*" >&2
exit 99
EOF
    } | _stub just
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
    assert_line '# chain: inbox-ok fish=4.2.1 tmux=yes host=ca83e9d035cd'
    assert_line 'ok 13 ghostty chain: a real window runs the managed block command'
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
