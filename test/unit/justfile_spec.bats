#!/usr/bin/env bats
# test/unit/justfile_spec.bats - `just` is THE user-facing interface (M2)
#
# WHAT THIS PROVES
#   The single repo-root justfile implements the fixed grammar and nothing
#   else, every recipe is a thin delegate to a script under script/, and
#   the dispatching recipes validate their argument BEFORE anything runs:
#
#     just                    -> just --list (build check lint selfcheck test assemble)
#     just build              -> ./script/ci/ci.sh --build
#     just lint               -> ./script/ci/ci.sh --lint-only
#     just test [tier]        -> ./script/ci/ci.sh --<tier>-only; `all` (default)
#                                runs unit, integration, system, acceptance,
#                                system-real IN THAT ORDER, stops at the first
#                                failure; an unknown tier exits 1 with the
#                                documented message and never reaches ci.sh
#     just check              -> lint, then test all (exactly what CI runs)
#     just selfcheck          -> ./script/selfcheck.sh
#     just assemble [mode] [file]
#                             -> ./script/assemble.sh --file <file>
#                                (default box/dev.ini); `dry-run` prefixes
#                                WORKTOOL_DRY_RUN=1; other modes exit 1
#
#   `just` works from any subdirectory of the checkout: just walks up to the
#   justfile and runs recipes in ITS directory, so the relative delegate
#   paths (./script/..., box/dev.ini) resolve the same everywhere.
#
#   justfile.ci is gone (one source of truth) and this spec is a REQUIRED
#   unit spec of ci.sh, so it cannot be deleted silently.
#
# HOW
#   Every case runs `just` against an independent COPY of the checkout
#   (justfile + script/ + lib/ + box/) under BATS_TEST_TMPDIR, never the
#   real tree, and never Docker: `just -n` (--dry-run) proves what a recipe
#   WOULD run without running it; the real dispatch is proven by running
#   the recipe for real in a copy whose script/ci/ci.sh, script/selfcheck.sh
#   and script/assemble.sh are STUBS that record their argv (and the
#   WORKTOOL_DRY_RUN they see) to a log. A fake `docker` that fails loudly
#   and records every call sits first on PATH for the whole spec, so a
#   regression that lets a bogus tier reach the REAL ci.sh shows up as a
#   recorded docker call instead of a real build.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    COPY="${BATS_TEST_TMPDIR}/copy"
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    export STUB_CALLS="${BATS_TEST_TMPDIR}/stub.calls"
    export FAKE_DOCKER_CALLS="${BATS_TEST_TMPDIR}/docker.calls"
    # The stubs record WORKTOOL_DRY_RUN only when a recipe sets it.
    unset WORKTOOL_DRY_RUN STUB_FAIL_ON
    _make_repo_copy
    _install_fake_docker
    export PATH="${FAKE_BIN}:${PATH}"
}

# Independent checkout copy at $COPY with the REAL scripts (cp -R keeps the
# executable bits).
_make_repo_copy() {
    mkdir -p "${COPY}"
    cp "${REPO_ROOT}/justfile" "${COPY}/justfile"
    cp -R "${REPO_ROOT}/script" "${REPO_ROOT}/lib" "${REPO_ROOT}/box" "${COPY}/"
}

# A `docker` that must never be reached: records the call and fails loudly.
_install_fake_docker() {
    mkdir -p "${FAKE_BIN}"
    cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"${FAKE_DOCKER_CALLS}"
printf 'fake docker: must not be called: docker %s\n' "$*" >&2
exit 99
EOF
    chmod +x "${FAKE_BIN}/docker"
}

# Replace the copy's three delegate targets with recording stubs. Each stub
# appends `<name> <args>[ WORKTOOL_DRY_RUN=<v>]` to $STUB_CALLS, prints a
# `STUB <name> <args>` marker, and fails (exit 7) when its first argument
# equals $STUB_FAIL_ON - the lever for the stop-at-first-failure case.
_stub_delegates() {
    local _s
    for _s in script/ci/ci.sh script/selfcheck.sh script/assemble.sh; do
        cat >"${COPY}/${_s}" <<'EOF'
#!/usr/bin/env bash
_me="$(basename -- "$0")"
_line="${_me}"
[[ $# -gt 0 ]] && _line+=" $*"
[[ -n "${WORKTOOL_DRY_RUN:-}" ]] && _line+=" WORKTOOL_DRY_RUN=${WORKTOOL_DRY_RUN}"
printf '%s\n' "${_line}" >>"${STUB_CALLS}"
printf 'STUB %s\n' "${_line}"
if [[ -n "${STUB_FAIL_ON:-}" && "${STUB_FAIL_ON}" == "${1:-}" ]]; then
    exit 7
fi
exit 0
EOF
        chmod +x "${COPY}/${_s}"
    done
}

# Run `just "$@"` against the copy (its justfile, its working directory).
_just() {
    run just --justfile "${COPY}/justfile" --working-directory "${COPY}" "$@"
}

# Run `just "$@"` from a SUBDIRECTORY of the copy with no --justfile /
# --working-directory: just must discover the copy's justfile by walking up
# and run the recipe in the justfile's directory.
_just_from_subdir() {
    mkdir -p "${COPY}/doc"
    run bash -c 'cd -- "$1" && shift && exec just "$@"' _ "${COPY}/doc" "$@"
}

# Print the recorded stub calls (empty when nothing was called).
_stub_calls() {
    [[ -f "${STUB_CALLS}" ]] && cat "${STUB_CALLS}"
    return 0
}

# Print the `./script/...` lines of the last `run` output, in order - what a
# dry run says it would execute.
_script_lines() {
    printf '%s\n' "${lines[@]}" | grep -E '^(WORKTOOL_DRY_RUN=1 )?\./script/' || true
}

# The five ci.sh tier calls in the order `test all` must run them.
ALL_TIERS_IN_ORDER="$(printf '%s\n' \
    'ci.sh --unit-only' \
    'ci.sh --integration-only' \
    'ci.sh --system-only' \
    'ci.sh --acceptance-only' \
    'ci.sh --system-real-only')"

ALL_TIERS_DRY_RUN="$(printf '%s\n' \
    './script/ci/ci.sh --unit-only' \
    './script/ci/ci.sh --integration-only' \
    './script/ci/ci.sh --system-only' \
    './script/ci/ci.sh --acceptance-only' \
    './script/ci/ci.sh --system-real-only')"

# --- the tool itself ---------------------------------------------------------

@test "just is installed in the test image and reports a semver" {
    run just --version
    assert_success
    assert_output --regexp '^just [0-9]+\.[0-9]+\.[0-9]+'
}

@test "justfile.ci is gone: one justfile is the single source of truth" {
    assert [ -f "${REPO_ROOT}/justfile" ]
    assert [ ! -e "${REPO_ROOT}/justfile.ci" ]
    run grep -n 'justfile\.ci' "${REPO_ROOT}/justfile" \
        "${REPO_ROOT}/script/ci/ci.sh" "${REPO_ROOT}/.github/workflows/ci.yml"
    assert_failure
    assert_output ""
}

@test "this spec is a required unit spec of ci.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/ci/ci.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# --- just --list: exactly the grammar, every recipe documented -------------

@test "just --list shows exactly default build check lint selfcheck test assemble, each with a comment" {
    _just --list
    assert_success
    local _names
    _names="$(printf '%s\n' "${lines[@]}" | sed -nE 's/^ +([A-Za-z_-]+).*$/\1/p' | sort | tr '\n' ' ')"
    assert_equal "${_names}" "assemble build check default lint selfcheck test "
    # Every listed recipe carries its doc comment.
    local _l
    for _l in "${lines[@]}"; do
        [[ "${_l}" == ' '* ]] || continue
        [[ "${_l}" == *" # "* ]] || fail "recipe without a comment: ${_l}"
    done
    # The two dispatching recipes advertise their parameters and defaults.
    assert_line --regexp "^ +test tier=['\"]all['\"] +# "
    assert_line --regexp "^ +assemble mode=['\"]run['\"] file=['\"]box/dev\.ini['\"] +# "
}

@test "bare just lists the recipes (default recipe = just --list)" {
    _just --list
    local _expected="${output}"
    _just
    assert_success
    assert_output "${_expected}"
}

# --- dry run: what each recipe would execute --------------------------------

@test "just -n build would run ./script/ci/ci.sh --build" {
    _stub_delegates
    _just -n build
    assert_success
    assert_equal "$(_script_lines)" "./script/ci/ci.sh --build"
    refute_output --partial "STUB"
}

@test "just -n lint would run ./script/ci/ci.sh --lint-only" {
    _stub_delegates
    _just -n lint
    assert_success
    assert_equal "$(_script_lines)" "./script/ci/ci.sh --lint-only"
    refute_output --partial "STUB"
}

@test "just -n selfcheck would run ./script/selfcheck.sh" {
    _stub_delegates
    _just -n selfcheck
    assert_success
    assert_equal "$(_script_lines)" "./script/selfcheck.sh"
    refute_output --partial "STUB"
}

@test "just -n test unit would run only ./script/ci/ci.sh --unit-only" {
    _stub_delegates
    _just -n test unit
    assert_success
    assert_equal "$(_script_lines)" "./script/ci/ci.sh --unit-only"
    refute_output --partial "STUB"
}

@test "just -n test system-real would run only ./script/ci/ci.sh --system-real-only" {
    _stub_delegates
    _just -n test system-real
    assert_success
    assert_equal "$(_script_lines)" "./script/ci/ci.sh --system-real-only"
    refute_output --partial "STUB"
}

@test "just -n test (all) would run unit, integration, system, acceptance, system-real in that order" {
    _stub_delegates
    _just -n test
    assert_success
    assert_equal "$(_script_lines)" "${ALL_TIERS_DRY_RUN}"
    refute_output --partial "STUB"
}

@test "just -n check would run lint, then the five tiers in order" {
    _stub_delegates
    _just -n check
    assert_success
    assert_equal "$(_script_lines)" "$(printf '%s\n' './script/ci/ci.sh --lint-only' "${ALL_TIERS_DRY_RUN}")"
    refute_output --partial "STUB"
}

@test "just -n assemble would run ./script/assemble.sh --file box/dev.ini without WORKTOOL_DRY_RUN" {
    _stub_delegates
    _just -n assemble
    assert_success
    assert_equal "$(_script_lines)" "./script/assemble.sh --file 'box/dev.ini'"
    refute_output --partial "WORKTOOL_DRY_RUN"
    refute_output --partial "STUB"
}

@test "just -n assemble dry-run would run WORKTOOL_DRY_RUN=1 ./script/assemble.sh --file box/dev.ini" {
    _stub_delegates
    _just -n assemble dry-run
    assert_success
    assert_equal "$(_script_lines)" "WORKTOOL_DRY_RUN=1 ./script/assemble.sh --file 'box/dev.ini'"
    refute_output --partial "STUB"
}

@test "just -n assemble dry-run /tmp/a.ini would pass --file /tmp/a.ini" {
    _stub_delegates
    _just -n assemble dry-run /tmp/a.ini
    assert_success
    assert_equal "$(_script_lines)" "WORKTOOL_DRY_RUN=1 ./script/assemble.sh --file '/tmp/a.ini'"
    refute_output --partial "STUB"
}

@test "just -n assemble run /tmp/x.ini would pass --file /tmp/x.ini without WORKTOOL_DRY_RUN" {
    _stub_delegates
    _just -n assemble run /tmp/x.ini
    assert_success
    assert_equal "$(_script_lines)" "./script/assemble.sh --file '/tmp/x.ini'"
    refute_output --partial "WORKTOOL_DRY_RUN"
    refute_output --partial "STUB"
}

# --- real dispatch: the recipes call the scripts with exactly these args ---

@test "just build / lint / selfcheck each call their script exactly once" {
    _stub_delegates
    _just build
    assert_success
    assert_equal "$(_stub_calls)" "ci.sh --build"

    : >"${STUB_CALLS}"
    _just lint
    assert_success
    assert_equal "$(_stub_calls)" "ci.sh --lint-only"

    : >"${STUB_CALLS}"
    _just selfcheck
    assert_success
    assert_equal "$(_stub_calls)" "selfcheck.sh"
}

@test "just test <tier> maps every single tier to its --<tier>-only flag and nothing else" {
    _stub_delegates
    local _tier
    for _tier in unit integration system system-real acceptance; do
        : >"${STUB_CALLS}"
        _just test "${_tier}"
        assert_success
        assert_output --partial "STUB ci.sh --${_tier}-only"
        assert_equal "$(_stub_calls)" "ci.sh --${_tier}-only"
    done
}

@test "just test (default all) runs the five tiers in order, system-real last" {
    _stub_delegates
    _just test
    assert_success
    assert_equal "$(_stub_calls)" "${ALL_TIERS_IN_ORDER}"
}

@test "just test all is the same as the default" {
    _stub_delegates
    _just test all
    assert_success
    assert_equal "$(_stub_calls)" "${ALL_TIERS_IN_ORDER}"
}

@test "just test (all) stops at the first failing tier" {
    _stub_delegates
    STUB_FAIL_ON=--system-only _just test
    assert_failure
    assert_equal "$(_stub_calls)" "$(printf '%s\n' \
        'ci.sh --unit-only' 'ci.sh --integration-only' 'ci.sh --system-only')"
}

@test "just check runs lint, then the five tiers in order" {
    _stub_delegates
    _just check
    assert_success
    assert_equal "$(_stub_calls)" "$(printf '%s\n' 'ci.sh --lint-only' "${ALL_TIERS_IN_ORDER}")"
}

@test "just check stops when lint fails: no tier runs" {
    _stub_delegates
    STUB_FAIL_ON=--lint-only _just check
    assert_failure
    assert_equal "$(_stub_calls)" "ci.sh --lint-only"
}

@test "just assemble runs ./script/assemble.sh --file box/dev.ini with WORKTOOL_DRY_RUN unset" {
    _stub_delegates
    _just assemble
    assert_success
    assert_equal "$(_stub_calls)" "assemble.sh --file box/dev.ini"
}

@test "just assemble run is the same as the default" {
    _stub_delegates
    _just assemble run
    assert_success
    assert_equal "$(_stub_calls)" "assemble.sh --file box/dev.ini"
}

@test "just assemble dry-run runs ./script/assemble.sh --file box/dev.ini with WORKTOOL_DRY_RUN=1" {
    _stub_delegates
    _just assemble dry-run
    assert_success
    assert_equal "$(_stub_calls)" "assemble.sh --file box/dev.ini WORKTOOL_DRY_RUN=1"
}

@test "just assemble run /tmp/x.ini passes that file, no WORKTOOL_DRY_RUN" {
    _stub_delegates
    _just assemble run /tmp/x.ini
    assert_success
    assert_equal "$(_stub_calls)" "assemble.sh --file /tmp/x.ini"
}

@test "just assemble dry-run <file> passes a path with spaces as one argument" {
    _stub_delegates
    _just assemble dry-run "/tmp/my box/a b.ini"
    assert_success
    assert_equal "$(_stub_calls)" "assemble.sh --file /tmp/my box/a b.ini WORKTOOL_DRY_RUN=1"
}

# --- real assemble.sh, dry-run: the delegate wiring end to end (no distrobox)

@test "just assemble dry-run prints distrobox assemble create --file box/dev.ini via the real script" {
    _just assemble dry-run
    assert_success
    assert_line "distrobox assemble create --file box/dev.ini"
}

@test "just assemble dry-run /tmp/a.ini validates that manifest via the real script" {
    printf '[dev]\nadditional_packages="ripgrep"\n' >"${BATS_TEST_TMPDIR}/a.ini"
    _just assemble dry-run "${BATS_TEST_TMPDIR}/a.ini"
    assert_failure 1
    assert_output --partial "[ERROR] manifest missing required key 'image' in section [dev]: ${BATS_TEST_TMPDIR}/a.ini"
    refute_output --partial "distrobox assemble create"
}

@test "just assemble dry-run from a subdirectory still resolves box/dev.ini at the repo root" {
    _just_from_subdir assemble dry-run
    assert_success
    assert_line "distrobox assemble create --file box/dev.ini"
}

@test "just test unit from a subdirectory still dispatches to ./script/ci/ci.sh at the repo root" {
    _stub_delegates
    _just_from_subdir test unit
    assert_success
    assert_equal "$(_stub_calls)" "ci.sh --unit-only"
}

# --- negative: invalid arguments fail before anything runs ------------------

@test "just test bogus exits 1 with the documented message and never reaches ci.sh or docker" {
    # REAL ci.sh in the copy: reaching it would hit the fake docker on PATH.
    _just test bogus
    assert_failure 1
    assert_output "just test: unknown tier 'bogus' (valid: unit integration system system-real acceptance all)"
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

@test "just test with an unknown tier is rejected regardless of stubs (quote-safe)" {
    _stub_delegates
    _just test "bo'gus"
    assert_failure 1
    assert_output "just test: unknown tier 'bo'gus' (valid: unit integration system system-real acceptance all)"
    assert_equal "$(_stub_calls)" ""
}

@test "just assemble bogus exits 1 with the documented message and never reaches assemble.sh" {
    _stub_delegates
    _just assemble bogus
    assert_failure 1
    assert_output "just assemble: unknown mode 'bogus' (valid: run dry-run)"
    assert_equal "$(_stub_calls)" ""
}

# --- CI runs the same grammar ------------------------------------------------

@test "ci.yml drives every gate through the just grammar, job names unchanged" {
    local _yml="${REPO_ROOT}/.github/workflows/ci.yml"
    # Matrix: job name (gate, keyed on by branch protection / ci-passed) ->
    # just recipe. The names are the pre-existing ones.
    local _pair _gate _recipe
    for _pair in 'lint=lint' 'test-unit=test unit' \
        'test-integration=test integration' 'test-system=test system' \
        'test-acceptance=test acceptance'; do
        _gate="${_pair%%=*}"
        _recipe="${_pair#*=}"
        run grep -A1 -E "^ +- gate: ${_gate}$" "${_yml}"
        assert_success
        assert_line --regexp "^ +recipe: ${_recipe}$"
    done
    run grep -E '^ +run: just ' "${_yml}"
    assert_success
    assert_line --regexp '^ +run: just \$\{\{ matrix\.recipe \}\}$'
    assert_line --regexp '^ +run: just test system-real$'
    # Exactly those two invocations: no gate bypasses the grammar.
    assert_equal "${#lines[@]}" 2
}
