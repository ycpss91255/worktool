#!/usr/bin/env bats
# test/unit/justfile_spec.bats - `just` is THE user interface, base model (M2)
#
# WHAT THIS PROVES
#   The just layer follows ycpss91255-docker/base (ADR-00000005/10/11):
#
#   - zero special cases: the root justfile is exactly two `mod?` lines
#     (test, box) plus a `default` that lists them - no other recipe;
#   - action-named namespaces: script/test/justfile.test and
#     script/box/justfile.box, each with its own `default`, `help` (alias
#     `h`) and `set working-directory := '../..'`, so every recipe runs at
#     the repo root wherever `just` is typed;
#   - min -> max: bare `just test` forwards to test.sh with NO argument
#     (= everything CI runs); each verb narrows to one `--<verb>` flag;
#   - thin forwarders: every recipe hands `*args` to its script VERBATIM,
#     argv boundaries intact (a path with spaces stays one argument), and
#     no justfile prints usage or a "valid: ..." list - validation and
#     --help live in the scripts, and a bogus recipe name is refused by
#     just itself before anything runs.
#
#   This spec is a REQUIRED unit spec of test.sh, so it cannot be deleted
#   silently.
#
# HOW
#   Every case runs `just` against an independent COPY of the checkout
#   (justfile + script/ + lib/ + box/) under BATS_TEST_TMPDIR, never the
#   real tree, and never Docker. Forwarding is proven by replacing the
#   copy's seven scripts (script/test/test.sh, script/test/selfcheck.sh,
#   script/box/assemble.sh, script/box/bench.sh, script/box/setup.sh,
#   script/box/status.sh, script/box/enter.sh) with STUBS that record their
#   argv - one %q per argument plus the argument COUNT - so a split or
#   merged argument shows up in the record. A fake `docker` that fails loudly and records every
#   call sits first on PATH for the whole spec, so a regression that lets
#   something reach the REAL test.sh shows up as a recorded docker call
#   instead of a real build. The dry-run cases run the REAL assemble.sh
#   (no distrobox needed); the real setup.sh / status.sh cases run under a
#   throwaway HOME.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    COPY="${BATS_TEST_TMPDIR}/copy"
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    export STUB_CALLS="${BATS_TEST_TMPDIR}/stub.calls"
    export FAKE_DOCKER_CALLS="${BATS_TEST_TMPDIR}/docker.calls"
    _make_repo_copy
    _install_fake_docker
    export PATH="${FAKE_BIN}:${PATH}"
}

# Independent checkout copy at $COPY with the REAL scripts and justfiles
# (cp -R keeps the executable bits).
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

# Replace the copy's seven forwarding targets with recording stubs. Each
# stub appends `<name>[ <%q arg>...]` to $STUB_CALLS and the argument count
# to $STUB_CALLS.argc, prints a `STUB <line>` marker and exits 0.
_stub_scripts() {
    local _s
    for _s in script/test/test.sh script/test/selfcheck.sh \
        script/box/assemble.sh script/box/bench.sh script/box/setup.sh script/box/status.sh \
        script/box/enter.sh; do
        cat >"${COPY}/${_s}" <<'EOF'
#!/usr/bin/env bash
_me="$(basename -- "$0")"
_line="${_me}"
# One %q per argument: argv boundaries survive in the record (a path with
# spaces shows as ONE backslash-escaped word, three words if it was split).
_args=""
[[ $# -gt 0 ]] && printf -v _args ' %q' "$@"
_line+="${_args}"
printf '%s\n' "$#" >>"${STUB_CALLS}.argc"
printf '%s\n' "${_line}" >>"${STUB_CALLS}"
printf 'STUB %s\n' "${_line}"
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
# --working-directory: just must discover the copy's justfile by walking up,
# and the module's working-directory setting must land at the copy root.
_just_from_subdir() {
    mkdir -p "${COPY}/doc"
    run bash -c 'cd -- "$1" && shift && exec just "$@"' _ "${COPY}/doc" "$@"
}

# Print the recorded stub calls (empty when nothing was called).
_stub_calls() {
    [[ -f "${STUB_CALLS}" ]] && cat "${STUB_CALLS}"
    return 0
}

# Print the argument count of the last recorded stub call.
_last_argc() {
    tail -n1 "${STUB_CALLS}.argc"
}

# Print the recipe names of a `--list` output (the first word of every
# indented line), sorted, space-joined.
_listed_names() {
    printf '%s\n' "${lines[@]}" | sed -nE 's/^ +([A-Za-z_-]+).*$/\1/p' | sort | tr '\n' ' '
}

# --- the tool itself ---------------------------------------------------------

@test "just is installed in the test image and reports a semver" {
    run just --version
    assert_success
    assert_output --regexp '^just [0-9]+\.[0-9]+\.[0-9]+'
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# --- zero special cases: the root justfile is namespaces + default only ----

@test "root justfile is exactly two mod? lines (test, box) and one default recipe" {
    assert [ -f "${REPO_ROOT}/justfile" ]
    assert [ ! -e "${REPO_ROOT}/justfile.ci" ]
    # Everything that is not a comment or blank line, verbatim.
    run grep -vE '^[[:space:]]*(#|$)' "${REPO_ROOT}/justfile"
    assert_success
    assert_equal "${#lines[@]}" 4
    assert_line --index 0 --regexp "^mod\? test +'script/test/justfile\.test'$"
    assert_line --index 1 --regexp "^mod\? box +'script/box/justfile\.box'$"
    assert_line --index 2 "default:"
    assert_line --index 3 --regexp '^[[:space:]]+@just --list$'
}

@test "the namespace justfiles live next to their scripts and run from the repo root" {
    local _m
    for _m in script/test/justfile.test script/box/justfile.box; do
        assert [ -f "${REPO_ROOT}/${_m}" ]
        run grep -xE "set working-directory := '\.\./\.\.'" "${REPO_ROOT}/${_m}"
        assert_success
    done
}

@test "no justfile prints usage or a valid: list of its own" {
    # Comment lines are allowed to TALK about the rule; recipe bodies and
    # settings must not carry usage text or option lists (case-insensitive).
    run bash -c "grep -vhE '^[[:space:]]*#' \"\$@\" | grep -niE 'valid:|usage'" _ \
        "${REPO_ROOT}/justfile" \
        "${REPO_ROOT}/script/test/justfile.test" "${REPO_ROOT}/script/box/justfile.box"
    assert_failure
    assert_output ""
}

# --- listing -----------------------------------------------------------------

@test "just --list shows the two namespaces and default, nothing else" {
    _just --list
    assert_success
    assert_equal "$(_listed_names)" "box default test "
    assert_line --regexp '^ +box \.\.\. +# '
    assert_line --regexp '^ +test \.\.\. +# '
}

@test "bare just is just --list" {
    _just --list
    local _expected="${output}"
    _just
    assert_success
    assert_output "${_expected}"
}

@test "just box lists assemble, bench, default, enter, help (alias h), setup and status only" {
    _just box
    assert_success
    assert_equal "$(_listed_names | sed 's/^h //; s/ h / /')" "assemble bench default enter help setup status "
    assert_output --regexp '\[alias: h\]|^ +h( |$)'
    refute_output --partial "test.sh"
    assert_equal "$(_stub_calls)" ""
}

# --- test namespace: min -> max, verbatim forwarding -------------------------

@test "just test (bare) forwards to test.sh with NO argument: everything CI runs" {
    _stub_scripts
    _just test
    assert_success
    assert_equal "$(_stub_calls)" "test.sh"
    assert_equal "$(_last_argc)" "0"
}

@test "just test <verb> forwards exactly --<verb> for every tier verb and build" {
    _stub_scripts
    local _verb
    for _verb in build lint unit matrix integration system system-real acceptance; do
        : >"${STUB_CALLS}"
        _just test "${_verb}"
        assert_success
        assert_equal "$(_stub_calls)" "test.sh --${_verb}"
        assert_equal "$(_last_argc)" "1"
    done
}

@test "just test lint --foo bar passes the extra arguments verbatim after --lint (argc 3)" {
    _stub_scripts
    _just test lint --foo bar
    assert_success
    assert_equal "$(_stub_calls)" "test.sh --lint --foo bar"
    assert_equal "$(_last_argc)" "3"
}

@test "just test selfcheck forwards to selfcheck.sh, --root X passing through" {
    _stub_scripts
    _just test selfcheck
    assert_success
    assert_equal "$(_stub_calls)" "selfcheck.sh"
    assert_equal "$(_last_argc)" "0"

    : >"${STUB_CALLS}"
    _just test selfcheck --root /tmp/other
    assert_success
    assert_equal "$(_stub_calls)" "selfcheck.sh --root /tmp/other"
    assert_equal "$(_last_argc)" "2"
}

@test "just test help and just test h forward test.sh --help" {
    _stub_scripts
    _just test help
    assert_success
    assert_equal "$(_stub_calls)" "test.sh --help"

    : >"${STUB_CALLS}"
    _just test h
    assert_success
    assert_equal "$(_stub_calls)" "test.sh --help"
    assert_equal "$(_last_argc)" "1"
}

# --- box namespace -----------------------------------------------------------

@test "just box assemble forwards to assemble.sh with no argument" {
    _stub_scripts
    _just box assemble
    assert_success
    assert_equal "$(_stub_calls)" "assemble.sh"
    assert_equal "$(_last_argc)" "0"
}

@test "just box assemble --dry-run --file <path with spaces> keeps argv boundaries (argc 3)" {
    _stub_scripts
    _just box assemble --dry-run --file "/tmp/my box/a b.ini"
    assert_success
    # %q-escaped: one word with escaped spaces, not three words.
    assert_equal "$(_stub_calls)" "assemble.sh --dry-run --file /tmp/my\\ box/a\\ b.ini"
    assert_equal "$(_last_argc)" "3"
}

@test "just box bench --runs 3 forwards to bench.sh verbatim (argc 2)" {
    _stub_scripts
    _just box bench --runs 3
    assert_success
    assert_equal "$(_stub_calls)" "bench.sh --runs 3"
    assert_equal "$(_last_argc)" "2"
}

@test "just box bench forwards to bench.sh with no argument" {
    _stub_scripts
    _just box bench
    assert_success
    assert_equal "$(_stub_calls)" "bench.sh"
    assert_equal "$(_last_argc)" "0"
}

@test "just box bench --shell 'sh -c :' keeps the shell command one argument (argc 2)" {
    _stub_scripts
    _just box bench --shell "sh -c :"
    assert_success
    # %q-escaped: one word with escaped spaces, not three words.
    assert_equal "$(_stub_calls)" "bench.sh --shell sh\\ -c\\ :"
    assert_equal "$(_last_argc)" "2"
}

@test "just box help and just box h forward --help to every box script, in order" {
    _stub_scripts
    _just box help
    assert_success
    assert_equal "$(_stub_calls)" "$(printf 'assemble.sh --help\nbench.sh --help\nsetup.sh --help\nstatus.sh --help\nenter.sh --help')"

    : >"${STUB_CALLS}"
    _just box h
    assert_success
    assert_equal "$(_stub_calls)" "$(printf 'assemble.sh --help\nbench.sh --help\nsetup.sh --help\nstatus.sh --help\nenter.sh --help')"
    assert_equal "$(_last_argc)" "1"
}

# #161 (4): the docs describe the same five scripts the recipe runs.
@test "README.md and doc/structure.md list all five scripts behind just box help, in order" {
    local _doc
    for _doc in README.md doc/structure.md; do
        run grep -E 'just box help.*assemble\.sh.*bench\.sh.*setup\.sh.*status\.sh.*enter\.sh' "${REPO_ROOT}/${_doc}"
        assert_success
    done
    run grep -E 'just box.*assemble.*bench.*setup.*status.*enter' "${REPO_ROOT}/README.md"
    assert_success
}

@test "just box setup forwards to setup.sh with no argument" {
    _stub_scripts
    _just box setup
    assert_success
    assert_equal "$(_stub_calls)" "setup.sh"
    assert_equal "$(_last_argc)" "0"
}

@test "just box setup --auto-enter no --tmux host --box <name with spaces> keeps argv boundaries (argc 6)" {
    _stub_scripts
    _just box setup --auto-enter no --tmux host --box "my box"
    assert_success
    assert_equal "$(_stub_calls)" "setup.sh --auto-enter no --tmux host --box my\\ box"
    assert_equal "$(_last_argc)" "6"
}

@test "just box status forwards to status.sh verbatim" {
    _stub_scripts
    _just box status
    assert_success
    assert_equal "$(_stub_calls)" "status.sh"
    assert_equal "$(_last_argc)" "0"

    : >"${STUB_CALLS}"
    _just box status --help
    assert_success
    assert_equal "$(_stub_calls)" "status.sh --help"
    assert_equal "$(_last_argc)" "1"
}

@test "just box enter forwards to enter.sh verbatim, the in-box command after -- included (#180)" {
    _stub_scripts
    _just box enter
    assert_success
    assert_equal "$(_stub_calls)" "enter.sh"
    assert_equal "$(_last_argc)" "0"

    : >"${STUB_CALLS}"
    _just box enter --box "my box" -- tmux new -A -s main
    assert_success
    assert_equal "$(_stub_calls)" "enter.sh --box my\\ box -- tmux new -A -s main"
    assert_equal "$(_last_argc)" "8"
}

@test "just box enter --bogus is refused by enter.sh itself (exit 2)" {
    _just box enter --bogus
    assert_failure 2
    assert_line "enter.sh: unknown option '--bogus' (see --help)"
}

# --- real assemble.sh, dry-run: the wiring end to end (no distrobox) ---------

@test "just box assemble --dry-run prints distrobox assemble create --file box/dev.ini via the real script" {
    _just box assemble --dry-run
    assert_success
    assert_line "distrobox assemble create --file box/dev.ini"
}

@test "just box assemble --dry-run --file <bad> validates that manifest via the real script" {
    printf '[dev]\nadditional_packages="ripgrep"\n' >"${BATS_TEST_TMPDIR}/a.ini"
    _just box assemble --dry-run --file "${BATS_TEST_TMPDIR}/a.ini"
    assert_failure 1
    assert_output --partial "[ERROR] manifest missing required key 'image' in section [dev]: ${BATS_TEST_TMPDIR}/a.ini"
    refute_line --regexp '^distrobox assemble create '
}

@test "just box assemble --bogus is refused by assemble.sh itself (exit 2), not by the justfile" {
    _just box assemble --bogus
    assert_failure 2
    assert_line "assemble.sh: unknown option '--bogus' (see --help)"
    refute_output --partial "valid:"
    refute_output --partial "Usage"
}

@test "just box bench --bogus is refused by bench.sh itself (exit 2), not by the justfile" {
    _just box bench --bogus
    assert_failure 2
    assert_line "bench.sh: unknown option '--bogus' (see --help)"
    refute_output --partial "valid:"
}

# --- real setup.sh / status.sh under a throwaway HOME: the wiring end to end

@test "just box setup --dry-run logs the decisions via the real script and writes nothing" {
    local _home="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_CONFIG_HOME="${_home}/.config" _just box setup --dry-run
    assert_success
    assert_line "[INFO] auto-enter: yes (default)"
    assert_line "[INFO] dry-run: would write ${_home}/.config/worktool/config"
    assert [ ! -e "${_home}/.config/worktool/config" ]
}

@test "just box status via the real script reports the defaults under a throwaway HOME" {
    local _home="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${_home}"
    HOME="${_home}" XDG_CONFIG_HOME="${_home}/.config" _just box status
    assert_success
    assert_line "auto-enter: yes (default)"
    assert_line "ghostty: ${_home}/.config/ghostty/config (managed block: absent)"
}

@test "just box setup --bogus and just box status --bogus are refused by the scripts themselves (exit 2)" {
    local _home="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${_home}"
    HOME="${_home}" _just box setup --bogus
    assert_failure 2
    assert_line "setup.sh: unknown option '--bogus' (see --help)"
    refute_output --partial "Usage"

    HOME="${_home}" _just box status --bogus
    assert_failure 2
    assert_line "status.sh: unknown option '--bogus' (see --help)"
    refute_output --partial "Usage"
}

# --- from a subdirectory: recipes still run at the repo root ----------------

@test "cd doc && just box assemble --dry-run resolves box/dev.ini at the repo root via the real script" {
    _just_from_subdir box assemble --dry-run
    assert_success
    assert_line "distrobox assemble create --file box/dev.ini"
}

@test "cd doc && just test unit still forwards to script/test/test.sh at the repo root" {
    _stub_scripts
    _just_from_subdir test unit
    assert_success
    assert_equal "$(_stub_calls)" "test.sh --unit"
}

# --- negative: a bogus recipe is just's own error, nothing runs -------------

@test "just test bogus fails with just's own recipe error, never reaching test.sh or docker" {
    # REAL test.sh in the copy: reaching it would hit the fake docker on PATH.
    _just test bogus
    assert_failure 1
    assert_output --regexp 'does not contain recipe.*bogus'
    refute_output --partial "valid:"
    refute_output --partial "Usage"
    assert [ ! -e "${FAKE_DOCKER_CALLS}" ]
}

@test "just test bogus is rejected regardless of stubs: no script is called" {
    _stub_scripts
    _just test bogus
    assert_failure
    assert_equal "$(_stub_calls)" ""
}

@test "just box bogus fails the same way" {
    _stub_scripts
    _just box bogus
    assert_failure 1
    assert_output --regexp 'does not contain recipe.*bogus'
    assert_equal "$(_stub_calls)" ""
}

# --- CI runs the same grammar ------------------------------------------------

@test "ci.yml drives every gate as just test <tier>, job names unchanged" {
    local _yml="${REPO_ROOT}/.github/workflows/ci.yml"
    # Matrix: job name (gate, keyed on by branch protection / ci-passed) ->
    # tier. The names are the pre-existing ones.
    local _pair _gate _tier
    for _pair in 'lint=lint' 'test-unit=unit' 'test-matrix=matrix' 'test-integration=integration' \
        'test-system=system' 'test-acceptance=acceptance'; do
        _gate="${_pair%%=*}"
        _tier="${_pair#*=}"
        run grep -A1 -E "^ +- gate: ${_gate}$" "${_yml}"
        assert_success
        assert_line --regexp "^ +tier: ${_tier}$"
    done
    run grep -E '^ +run: just ' "${_yml}"
    assert_success
    assert_line --regexp '^ +run: just test \$\{\{ matrix\.tier \}\}$'
    assert_line --regexp '^ +run: just test system-real$'
    # Exactly those two invocations: no gate bypasses the grammar.
    assert_equal "${#lines[@]}" 2
}
