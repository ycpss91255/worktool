#!/usr/bin/env bats
# test/unit/verify_ui_spec.bats - script/verify/ui.sh cannot false-pass (M3)
#
# WHAT THIS PROVES
#   script/verify/ui.sh is the executable form of doc/acceptance.md's M3
#   item 1.1. An acceptance check is worth nothing unless a broken check
#   reads RED, so this spec attacks the script from the only direction that
#   matters: it makes each stage the script depends on FAIL WHILE STILL
#   PRINTING PLAUSIBLE OUTPUT, and asserts the script still exits non-zero.
#
#   The stages, and the case that breaks each one:
#     just box            - exits 1 with the documented recipe list
#     just box            - exits 0 with nothing / without the header
#     just box help       - exits 1 with the five documented Usage lines
#     grep '^Usage:'      - exits 2 with the five documented Usage lines
#     grep -o             - exits 2 with the five documented script names
#     sort -u             - exits 1 with the five documented script names
#     wc -l               - exits 1 printing `5`, and exits 0 printing a word
#     timeout             - exits 1 with the documented recipe list
#     timeout             - kills a `just box help` that never returns (124)
#
#   Plus the degenerate counts that must not read like a pass (a recipe list
#   missing a verb, three usages, four Usage lines from ONE script), the
#   UNAVAILABLE contract (a missing tool exits non-zero and says so - the
#   script never skips), and the CLI contract (--help 0, unknown option 2
#   naming the option, unknown item 2, no argument = every item).
#
# HOW
#   Every stub is a real executable in a per-test $FAKE_BIN placed FIRST on
#   PATH for the duration of one `run`, so nothing leaks into bats itself.
#   Tool stubs (grep, sort, wc, timeout) misbehave only for the call the
#   script makes and `exec` the real tool otherwise, so a stub can never
#   turn a case red for an unrelated reason. The control cases run the REAL
#   `just` against this checkout with no stub at all, which is what keeps
#   the negative assertions from being vacuous.
#
#   No Docker, no distrobox, no box: item 1.1 only reads `just`.

load "${BATS_TEST_DIRNAME}/../helper/common"

UI_SH="${REPO_ROOT}/script/verify/ui.sh"

setup() {
    REAL_JUST="$(command -v just)"
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${FAKE_BIN}"
}

# --- Stub plumbing -----------------------------------------------------------

# _stub <name>  - body on stdin. The body runs with $REAL set to the real
# executable of that name (resolved before PATH is touched), so a stub can
# delegate every call it does not want to break: `exec "${REAL}" "$@"`.
_stub() {
    local _name="$1" _real=""
    _real="$(command -v "${_name}")" || _real=""
    {
        printf '#!/usr/bin/env bash\n'
        printf 'REAL=%q\n' "${_real}"
        cat
    } >"${FAKE_BIN}/${_name}"
    chmod +x "${FAKE_BIN}/${_name}"
}

# Generate shell printf statements from real product output before stubbing.
_usage_lines_body() {
    local _help _line
    _help="$("${REAL_JUST}" box help 2>&1)" || return 1
    while IFS= read -r _line; do
        [[ "${_line}" == Usage:* ]] || continue
        printf "printf '%%s\\n' %q\n" "${_line}"
    done <<<"${_help}"
}

_recipe_lines_body() {
    local _list _line
    _list="$("${REAL_JUST}" box)" || return 1
    while IFS= read -r _line; do
        printf "printf '%%s\\n' %q\n" "${_line}"
    done <<<"${_list}"
}

# A `just` stub that prints exactly what the document shows and exits $1
# (default 0). Everything the real just would print for `box` / `box help`,
# nothing else.
_stub_just_documented() {
    local _rc="${1:-0}"
    {
        cat <<'EOF'
if [ "${1:-}" = box ] && [ "${2:-}" = help ]; then
    printf './script/box/assemble.sh --help\n'
EOF
        _usage_lines_body
        cat <<EOF
    exit ${_rc}
fi
EOF
        cat <<'EOF'
if [ "${1:-}" = box ]; then
EOF
        _recipe_lines_body
        cat <<EOF
    exit ${_rc}
fi
exit 1
EOF
    } | _stub just
}

# --- Control: the real thing, so the negatives are not vacuous ---------------

@test "control: item 1.1 passes against this checkout and prints the documented lines" {
    run "${UI_SH}" 1.1
    assert_success
    assert_line 'Available recipes:'
    assert_line --partial 'assemble *args #'
    assert_line --partial 'bench *args    #'
    assert_line --partial 'default '
    assert_line --partial 'enter *args'
    assert_line --partial 'help '
    assert_line --partial 'setup *args    #'
    assert_line --partial 'status *args   #'
    assert_line --partial 'Usage: assemble.sh'
    assert_line --partial 'Usage: bench.sh'
    assert_line --partial 'Usage: setup.sh'
    assert_line 'Usage: status.sh'
    assert_line --partial 'Usage: enter.sh'
    assert_line 'five-usages'
}

@test "control: no argument runs the same items as naming 1.1 explicitly" {
    run "${UI_SH}" 1.1
    assert_success
    local _named="${output}"
    run "${UI_SH}"
    assert_success
    assert_equal "${output}" "${_named}"
}

@test "control: the documented just stub passes, so every stub below differs in ONE way" {
    _stub_just_documented 0
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_success
    assert_line 'five-usages'
}

# --- The false-pass this work removes: plausible output, non-zero status -----

@test "false-pass guard: just box printing the documented recipe list but exiting 1 fails" {
    _stub_just_documented 1
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial 'exited 1 - what it printed does not count'
    refute_output --partial 'five-usages'
}

@test "false-pass guard: just box help printing the five Usage lines but exiting 1 fails" {
    {
        cat <<'EOF'
if [ "${1:-}" = box ] && [ "${2:-}" = help ]; then
EOF
        _usage_lines_body
        cat <<'EOF'
    exit 1
fi
if [ "${1:-}" = box ]; then
    printf 'Available recipes:\n'
    printf '    assemble *args # x\n    bench *args # x\n    default # x\n'
    printf '    enter *args # x\n'
    printf '    help # x\n    setup *args # x\n    status *args # x\n'
    exit 0
fi
exit 1
EOF
    } | _stub just
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial 'exited 1 - what it printed does not count'
    refute_output --partial 'five-usages'
}

@test "false-pass guard: grep printing the five Usage lines but exiting 2 fails" {
    _stub_just_documented 0
    {
        cat <<'EOF'
for _a in "$@"; do
    if [ "${_a}" = '^Usage:' ]; then
        cat >/dev/null
EOF
        _usage_lines_body
        cat <<'EOF'
        exit 2
    fi
done
exec "${REAL}" "$@"
EOF
    } | _stub grep
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial "grep '^Usage:' failed (exit 2)"
    refute_output --partial 'five-usages'
}

@test "false-pass guard: grep -o printing the five script names but exiting 2 fails" {
    _stub_just_documented 0
    _stub grep <<'EOF'
for _a in "$@"; do
    if [ "${_a}" = '^Usage: [a-z]*\.sh' ]; then
        cat >/dev/null
        printf 'Usage: assemble.sh\nUsage: bench.sh\nUsage: setup.sh\nUsage: status.sh\nUsage: enter.sh\n'
        exit 2
    fi
done
exec "${REAL}" "$@"
EOF
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial 'failed (exit 2)'
    refute_output --partial 'five-usages'
}

@test "false-pass guard: sort printing the five script names but exiting 1 fails" {
    _stub_just_documented 0
    _stub sort <<'EOF'
cat >/dev/null
printf 'Usage: assemble.sh\nUsage: bench.sh\nUsage: setup.sh\nUsage: status.sh\nUsage: enter.sh\n'
exit 1
EOF
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial 'sort -u failed (exit 1)'
    refute_output --partial 'five-usages'
}

@test "false-pass guard: wc printing 5 but exiting 1 fails" {
    _stub_just_documented 0
    _stub wc <<'EOF'
cat >/dev/null
printf '5\n'
exit 1
EOF
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial 'wc -l failed (exit 1)'
    refute_output --partial 'five-usages'
}

@test "false-pass guard: wc printing a word instead of a count fails before the comparison" {
    _stub_just_documented 0
    # Exceed pipe capacity so an early-exit wc always SIGPIPEs the writer.
    _stub sort <<'EOF'
cat >/dev/null
printf '%1048576s\n' x
EOF
    _stub wc <<'EOF'
cat >/dev/null
printf 'four\n'
exit 0
EOF
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial "wc -l printed 'four', which is not a count"
    refute_output --partial 'five-usages'
}

@test "false-pass guard: timeout printing the documented recipe list but exiting 1 fails" {
    _stub_just_documented 0
    _stub timeout <<'EOF'
printf 'Available recipes:\n'
printf '    assemble *args # x\n    bench *args # x\n    default # x\n'
printf '    help # x\n    setup *args # x\n    status *args # x\n'
exit 1
EOF
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial 'exited 1 - what it printed does not count'
    refute_output --partial 'five-usages'
}

@test "false-pass guard: a just box help that never returns is killed and fails" {
    {
        cat <<'EOF'
if [ "${1:-}" = box ] && [ "${2:-}" = help ]; then
EOF
        _usage_lines_body
        cat <<'EOF'
    exec sleep 20
fi
if [ "${1:-}" = box ]; then
    printf 'Available recipes:\n'
    printf '    assemble *args # x\n    bench *args # x\n    default # x\n'
    printf '    enter *args # x\n'
    printf '    help # x\n    setup *args # x\n    status *args # x\n'
    exit 0
fi
exit 1
EOF
    } | _stub just
    VERIFY_TIMEOUT=1 PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial 'did not finish within 1s (timeout)'
    refute_output --partial 'five-usages'
}

# --- Degenerate counts must not read like a pass -----------------------------

@test "degenerate: just box exiting 0 with no output fails as empty, not as zero recipes" {
    _stub just <<'EOF'
exit 0
EOF
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial 'exited 0 but printed nothing'
}

@test "degenerate: a recipe list without the Available recipes: header fails" {
    _stub just <<'EOF'
if [ "${1:-}" = box ]; then
    printf '    assemble *args # x\n    bench *args # x\n    default # x\n'
    printf '    enter *args # x\n'
    printf '    help # x\n    setup *args # x\n    status *args # x\n'
    exit 0
fi
exit 1
EOF
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial "printed no 'Available recipes:' header"
}

@test "degenerate: a recipe list missing the status verb fails and names it" {
    _stub just <<'EOF'
if [ "${1:-}" = box ]; then
    printf 'Available recipes:\n'
    printf '    assemble *args # x\n    bench *args # x\n    default # x\n'
    printf '    enter *args # x\n'
    printf '    help # x\n    setup *args # x\n'
    exit 0
fi
exit 1
EOF
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial 'does not list: status'
}

@test "degenerate: just box help printing three script usages fails" {
    {
        cat <<'EOF'
if [ "${1:-}" = box ] && [ "${2:-}" = help ]; then
    printf 'Usage: assemble.sh [--file <manifest>]\n'
    printf 'Usage: bench.sh [--box NAME]\n'
    printf 'Usage: setup.sh [--auto-enter yes|no]\n'
    exit 0
fi
if [ "${1:-}" = box ]; then
    printf 'Available recipes:\n'
    printf '    assemble *args # x\n    bench *args # x\n    default # x\n'
    printf '    enter *args # x\n'
    printf '    help # x\n    setup *args # x\n    status *args # x\n'
    exit 0
fi
exit 1
EOF
    } | _stub just
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial 'prints 3 distinct script usage(s), expected 5'
    refute_output --partial 'five-usages'
}

@test "degenerate: five Usage lines from ONE script are not five script usages" {
    {
        cat <<'EOF'
if [ "${1:-}" = box ] && [ "${2:-}" = help ]; then
    printf 'Usage: assemble.sh [--file <manifest>]\n'
    printf 'Usage: assemble.sh [--dry-run]\n'
    printf 'Usage: assemble.sh [-h]\n'
    printf 'Usage: assemble.sh [--help]\n'
    printf 'Usage: assemble.sh [--home PATH]\n'
    exit 0
fi
if [ "${1:-}" = box ]; then
    printf 'Available recipes:\n'
    printf '    assemble *args # x\n    bench *args # x\n    default # x\n'
    printf '    enter *args # x\n'
    printf '    help # x\n    setup *args # x\n    status *args # x\n'
    exit 0
fi
exit 1
EOF
    } | _stub just
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial 'prints 1 distinct script usage(s), expected 5'
    refute_output --partial 'five-usages'
}

@test "degenerate: just box help exiting 0 with no Usage line fails" {
    {
        cat <<'EOF'
if [ "${1:-}" = box ] && [ "${2:-}" = help ]; then
    printf './script/box/assemble.sh --help\n'
    exit 0
fi
if [ "${1:-}" = box ]; then
    printf 'Available recipes:\n'
    printf '    assemble *args # x\n    bench *args # x\n    default # x\n'
    printf '    enter *args # x\n'
    printf '    help # x\n    setup *args # x\n    status *args # x\n'
    exit 0
fi
exit 1
EOF
    } | _stub just
    PATH="${FAKE_BIN}:${PATH}" run "${UI_SH}" 1.1
    assert_failure 1
    assert_output --partial "no line matching '^Usage:'"
}

# --- A check that cannot run here is not a skip ------------------------------

@test "unavailable: a missing just is reported and exits non-zero, never skipped" {
    local _stripped="${BATS_TEST_TMPDIR}/nojust"
    mkdir -p "${_stripped}"
    local _tool
    for _tool in bash timeout grep sort wc; do
        ln -sf "$(command -v "${_tool}")" "${_stripped}/${_tool}"
    done
    PATH="${_stripped}" run "${UI_SH}" 1.1
    assert_failure 3
    assert_output --partial '[UNAVAILABLE]'
    assert_output --partial 'just not found on PATH'
    refute_output --partial 'five-usages'
}

@test "unavailable: a missing wc is reported and exits non-zero, never skipped" {
    local _stripped="${BATS_TEST_TMPDIR}/nowc"
    mkdir -p "${_stripped}"
    local _tool
    for _tool in bash just timeout grep sort; do
        ln -sf "$(command -v "${_tool}")" "${_stripped}/${_tool}"
    done
    PATH="${_stripped}" run "${UI_SH}" 1.1
    assert_failure 3
    assert_output --partial '[UNAVAILABLE]'
    assert_output --partial 'wc not found on PATH'
    refute_output --partial 'five-usages'
}

# --- CLI contract ------------------------------------------------------------

@test "cli: --help exits 0 and documents the exit codes" {
    run "${UI_SH}" --help
    assert_success
    assert_output --partial 'Usage: ui.sh [ITEM...]'
    assert_output --partial '3 the check cannot run'
}

@test "cli: an unknown option exits 2 and names the option" {
    run "${UI_SH}" --bogus
    assert_failure 2
    assert_output --partial "ui.sh: unknown option '--bogus' (see --help)"
}

@test "cli: an unknown item exits 2 and names the item" {
    run "${UI_SH}" 9.9
    assert_failure 2
    assert_output --partial "ui.sh: unknown item '9.9' (see --help)"
}

@test "cli: --list prints the registered item ids" {
    run "${UI_SH}" --list
    assert_success
    assert_line --partial '1.1  just box lists seven verbs'
}

@test "single source: UI fixture usages and recipes equal real just output" {
    local _real_help _real_list _fixture_help _fixture_list
    run just box help
    assert_success
    _real_help="$(printf '%s\n' "${output}" | grep '^Usage:')"
    run just box
    assert_success
    _real_list="$(printf '%s\n' "${output}" | sed 's/ *#.*//')"
    _stub_just_documented
    run "${FAKE_BIN}/just" box help
    assert_success
    _fixture_help="$(printf '%s\n' "${output}" | grep '^Usage:')"
    assert_equal "${_fixture_help}" "${_real_help}"
    run "${FAKE_BIN}/just" box
    assert_success
    _fixture_list="$(printf '%s\n' "${output}" | sed 's/ *#.*//')"
    assert_equal "${_fixture_list}" "${_real_list}"
}

@test "single source: documented Usage lines occur in real product help" {
    local _help _line
    run just box help
    assert_success
    _help="${output}"
    run just test help
    assert_success
    _help+=$'\n'"${output}"
    while IFS= read -r _line; do
        run grep -Fx "${_line}" <<<"${_help}"
        assert_success
    done < <(sed -n 's/^ *\(Usage: .*\)$/\1/p' "${REPO_ROOT}/doc/acceptance.md")
}
