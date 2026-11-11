#!/usr/bin/env bats
# test/unit/justfile_spec.bats - `just` is THE user interface, base model (M2)
#
# WHAT THIS PROVES
#   The just layer follows ycpss91255-docker/base (ADR-00000005/10/11):
#
#   - zero special cases: the root justfile is action `mod?` lines
#     (test, box, verify, agent, worktree, job) plus a `default` that lists them - no other recipe;
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
    mkdir -p "${COPY}/.agents/script"
    cp "${REPO_ROOT}/.agents/script/job.sh" "${REPO_ROOT}/.agents/script/justfile.job" "${COPY}/.agents/script/"
    cp -R "${REPO_ROOT}/.agents/script/worktree" "${COPY}/.agents/script/"
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

# Only exact first fields of space-indented entries count as recipes.
# Aliases may also appear as exact comma-separated names in a trailing alias tag.
# Usage: _recipe_entry_gaps "<recipes>" "<aliases>" <<<"<listing>"
_recipe_entry_gaps() {
    local recipes="$1" aliases="${2:-}" rc=0
    awk -v recipes="$recipes" -v aliases="$aliases" '
        /^ +[^[:space:]]+( |$)/ {
            entries[$1] = 1
            if (match($0, /\[alias: [^][]*\]$/)) {
                tag = substr($0, RSTART + 8, RLENGTH - 9)
                count = split(tag, names, ",")
                for (i = 1; i <= count; i++) {
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", names[i])
                    listed_aliases[names[i]] = 1
                }
            }
        }
        END {
            count = split(recipes, names, /[[:space:]]+/)
            for (i = 1; i <= count; i++) {
                name = names[i]
                if (name != "" && !(name in entries)) {
                    print "missing recipe entry: " name
                    missing = 1
                }
            }
            count = split(aliases, names, /[[:space:]]+/)
            for (i = 1; i <= count; i++) {
                name = names[i]
                if (name != "" && !(name in entries) && !(name in listed_aliases)) {
                    print "missing alias entry: " name
                    missing = 1
                }
            }
            exit missing
        }
    ' || rc=$?
    return "$rc"
}

# Follow the canonical root pointer and compare its listing with the JSON dump.
_namespace_guidance_gaps() {
    local root="$1" namespace="$2" root_listing description listing dump module recipes aliases rc=0
    if ! root_listing=$(just --justfile "${root}/justfile" --working-directory "$root" --list); then
        printf 'namespace guidance check: root listing failed: %s\n' "$namespace" >&2
        return 1
    fi
    if ! description=$(awk -v ns="$namespace" '
        /^ +/ && $1 == ns && $2 == "..." {
            line = $0
            if (sub(/^ +[^ ]+ \.\.\. +# /, "", line)) print line
        }
    ' <<<"$root_listing"); then
        printf 'namespace guidance check: description extraction failed: %s\n' "$namespace" >&2
        return 1
    fi
    if [[ -z "$description" ]]; then
        printf 'no root listing entry: %s\n' "$namespace"
        return 1
    fi
    if [[ "$description" != *"; just --list ${namespace} lists its recipes." ]]; then
        printf 'no canonical pointer: %s: %s\n' "$namespace" "$description"
        return 1
    fi
    if ! listing=$(just --justfile "${root}/justfile" --working-directory "$root" --list "$namespace"); then
        printf 'namespace guidance check: namespace listing failed: %s\n' "$namespace" >&2
        return 1
    fi
    if ! dump=$(just --justfile "${root}/justfile" --dump --dump-format json); then
        printf 'namespace guidance check: just --dump failed\n' >&2
        return 1
    fi
    if ! module=$(jq -c --arg ns "$namespace" '.modules[$ns]' <<<"$dump"); then
        printf 'namespace guidance check: JSON module extraction failed: %s\n' "$namespace" >&2
        return 1
    fi
    if [[ "$module" == null ]]; then
        printf 'module not loaded: %s\n' "$namespace"
        return 1
    fi
    if ! recipes=$(jq -r '.recipes | to_entries[] | select(.value.private != true) | .key' <<<"$module"); then
        printf 'namespace guidance check: JSON recipe listing failed: %s\n' "$namespace" >&2
        return 1
    fi
    if ! aliases=$(jq -r '.aliases | keys[]' <<<"$module"); then
        printf 'namespace guidance check: JSON alias listing failed: %s\n' "$namespace" >&2
        return 1
    fi
    _recipe_entry_gaps "$recipes" "$aliases" <<<"$listing" || rc=$?
    return "$rc"
}

# Check command rows against the public listing: mod? lines + just --dump JSON.
_command_row_gaps() {
    local dump modules listing
    if ! dump=$(just --justfile "${1}/justfile" --dump --dump-format json); then
        printf 'command-row check: just --dump failed\n' >&2
        return 1
    fi
    if ! modules=$(awk '/^mod\?[[:space:]]+/ { print $2 }' "${1}/justfile"); then
        printf 'command-row check: module listing failed\n' >&2
        return 1
    fi
    if ! listing=$(jq -er --arg modules "${modules}" '
        def commands($prefix):
            ((.recipes | to_entries[] | select(.value.private != true) | .key),
             (.aliases | keys[])) |
            $prefix + (if . == "default" then "" else " " + . end);
        . as $dump |
        [commands("just"),
         ($modules | split("\n")[] | select(length > 0) | . as $ns |
          if ($dump.modules | has($ns)) then
              $dump.modules[$ns] | commands("just " + $ns)
          else
              "module not loaded: " + $ns
          end)] | join("\n")
    ' <<<"${dump}"); then
        printf 'command-row check: JSON listing failed\n' >&2
        return 1
    fi
    awk '
        FILENAME != "-" {
            if (!/^\| `just/) next
            split($0, cells, "|")
            count = split(cells[2], spans, "`")
            for (i = 2; i <= count; i += 2) {
                command = spans[i]
                sub(/ [\[<].*$/, "", command)
                documented[command] = 1
            }
            next
        }
        /^module not loaded: / {
            print
            missing = 1
            next
        }
        NF {
            if (!($0 in documented)) {
                print "missing command row: " $0
                missing = 1
            }
        }
        END { exit missing }
    ' "${1}/doc/structure.md" - <<<"${listing}"
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

@test "root justfile is six mod? lines (test, box, verify, agent, worktree, job) and one default recipe" {
    assert [ -f "${REPO_ROOT}/justfile" ]
    assert [ ! -e "${REPO_ROOT}/justfile.ci" ]
    # Everything that is not a comment or blank line, verbatim.
    run grep -vE '^[[:space:]]*(#|$)' "${REPO_ROOT}/justfile"
    assert_success
    assert_equal "${#lines[@]}" 8
    assert_line --index 0 --regexp "^mod\? test +'script/test/justfile\.test'$"
    assert_line --index 1 --regexp "^mod\? box +'script/box/justfile\.box'$"
    assert_line --index 2 --regexp "^mod\? verify +'script/verify/justfile\.verify'$"
    assert_line --index 3 --regexp "^mod\? agent +'script/agent/justfile\.agent'$"
    assert_line --index 4 --regexp "^mod\\? worktree +'.agents/script/worktree/justfile\\.worktree'$"
    assert_line --index 5 --regexp "^mod\\? job +'.agents/script/justfile\\.job'$"
    assert_line --index 6 "default:"
    assert_line --index 7 --regexp '^[[:space:]]+@just --list$'
}

# Print each root module with its doc comment in declaration order.
_root_mod_comments() {
    awk '
        /^# / { comment = substr($0, 3) }
        /^mod[?] / { print $1, $2, $3, "# " comment }
        # Only adjacent doc comments belong to a module; clear after printing it.
        !/^# / { comment = "" }
    ' "$1"
}

@test "#701: root module comments do not carry across blank lines or recipe code" {
    local _fixture="${BATS_TEST_TMPDIR}/justfile.comments"
    cat >"${_fixture}" <<'EOF'
# First doc.
mod? a 'a/justfile.a'

mod? b 'b/justfile.b'
default:
    @just --list
mod? c 'c/justfile.c'
EOF
    run _root_mod_comments "${_fixture}"
    assert_success
    assert_equal "${#lines[@]}" 3
    assert_line --index 0 "mod? a 'a/justfile.a' # First doc."
    assert_line --index 1 "mod? b 'b/justfile.b' # "
    assert_line --index 2 "mod? c 'c/justfile.c' # "
}

@test "#701: design root justfile block matches namespace names, paths and doc comments in order" {
    local _actual
    _actual="$(_root_mod_comments "${REPO_ROOT}/justfile")"
    run awk '
        /^```just$/ { block = 1; next }
        block && /^```$/ { exit }
        block && /^mod[?] / {
            comment = $0
            sub(/^[^#]*# /, "", comment)
            print $1, $2, $3, "# " comment
        }
    ' "${REPO_ROOT}/doc/design.md"
    assert_success
    assert_output "${_actual}"
}

@test "the namespace justfiles live next to their scripts and run from the repo root" {
    local _m
    for _m in script/test/justfile.test script/box/justfile.box script/verify/justfile.verify .agents/script/justfile.job; do
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
        "${REPO_ROOT}/script/test/justfile.test" "${REPO_ROOT}/script/box/justfile.box" \
        "${REPO_ROOT}/script/verify/justfile.verify"
    assert_failure
    assert_output ""
}

# --- listing -----------------------------------------------------------------

@test "just --list shows the six namespaces and default, nothing else" {
    _just --list
    assert_success
    assert_equal "$(_listed_names)" "agent box default job test verify worktree "
    assert_line --regexp '^ +box \.\.\. +# '
    assert_line --regexp '^ +test \.\.\. +# '
    assert_line --regexp '^ +verify \.\.\. +# '
}

@test "bare just is just --list" {
    _just --list
    local _expected="${output}"
    _just
    assert_success
    assert_output "${_expected}"
}

@test "#707: recipe entry check rejects names that appear only in prose" {
    local listing='Available recipes:
    default # Run all.sh with --help first.'
    run _recipe_entry_gaps "default all help" <<<"$listing"
    assert_failure
    assert_line "missing recipe entry: all"
    assert_line "missing recipe entry: help"
    refute_line "missing recipe entry: default"
}

@test "#707: recipe entry check accepts listed entries and inline aliases" {
    local listing='Available recipes:
    default # Run all.sh with --help first.
    all *args # Run everything.
    help # Show help. [alias: h, hh]'
    run _recipe_entry_gaps "default all help" "h hh" <<<"$listing"
    assert_success
    assert_output ""

    run _recipe_entry_gaps "default all help" "hx" <<<"$listing"
    assert_failure
    assert_output "missing alias entry: hx"
}

@test "#707: namespace guidance rejects a root comment without the canonical pointer" {
    local root="${BATS_TEST_TMPDIR}/pointer"
    mkdir -p "${root}/demo"
    cat >"${root}/justfile" <<'EOF'
# Demo; see just demo help.
mod? demo 'demo/justfile.demo'
default:
    @just --list
EOF
    cat >"${root}/demo/justfile.demo" <<'EOF'
default:
    @echo demo
help:
    @echo help
EOF
    run _namespace_guidance_gaps "$root" demo
    assert_failure
    assert_output --partial "no canonical pointer: demo"
}

@test "#707: namespace guidance accepts the canonical pointer when every recipe is listed" {
    local root="${BATS_TEST_TMPDIR}/canonical-pointer"
    mkdir -p "${root}/demo"
    cat >"${root}/justfile" <<'EOF'
# Demo; just --list demo lists its recipes.
mod? demo 'demo/justfile.demo'
default:
    @just --list
EOF
    cat >"${root}/demo/justfile.demo" <<'EOF'
default:
    @echo demo
help:
    @echo help
EOF
    run _namespace_guidance_gaps "$root" demo
    assert_success
    assert_output ""
}

@test "#707: root namespace guidance covers every current user recipe" {
    local namespace namespaces gaps="" rc=0
    run awk '/^mod\?[[:space:]]+/ { print $2 }' "${COPY}/justfile"
    assert_success
    assert_equal "${#lines[@]}" 6
    namespaces="$output"
    for namespace in $namespaces; do
        gaps+="$(_namespace_guidance_gaps "${COPY}" "$namespace")" || rc=$?
    done
    assert_equal "${gaps}" ""
    assert_equal "$rc" 0
}

@test "#665: box descriptions do not promise rm in M3" {
    local _stale_promise='((adds|再加|later)[[:space:]]+rm|adds[[:space:]]+enter[[:space:]]*/[[:space:]]*rm)([[:space:][:punct:]]|$)'
    _just --list
    assert_success
    refute_output --regexp "${_stale_promise}"

    run grep -nE "${_stale_promise}" \
        "${REPO_ROOT}/justfile" \
        "${REPO_ROOT}/doc/structure.md" \
        "${REPO_ROOT}/script/box/justfile.box" \
        "${REPO_ROOT}/doc/design.md"
    assert_failure 1
    assert_output ""
}

@test "just box lists assemble, bench, default, enter, help (alias h), setup and status only" {
    _just box
    assert_success
    assert_equal "$(_listed_names | sed 's/^h //; s/ h / /')" "assemble bench default enter help setup status "
    assert_output --regexp '\[alias: h\]|^ +h( |$)'
    refute_output --partial "test.sh"
    assert_equal "$(_stub_calls)" ""
}

@test "#720: just box lists the bench max-wait option" {
    _just --list box
    assert_success
    assert_line --regexp '^ +bench .*--max-wait N'
}

@test "#720: just verify lists the setup real-box opt-in" {
    _just --list verify
    assert_success
    assert_line --regexp '^ +setup .*args: ITEM, --list, --allow-real-box, --help'
}

@test "#720: just verify lists the diagram list and realbox options" {
    _just --list verify
    assert_success
    assert_line --regexp '^ +diagram .*args: ITEM, --root <repo>, --list, --realbox, --help'
}

@test "#720: just verify lists the realbox list option" {
    _just --list verify
    assert_success
    assert_line --regexp '^ +realbox .*args: ITEM, --list, --allow-real-box'
}

@test "#720: just verify lists the evidence realbox opt-in" {
    _just --list verify
    assert_success
    assert_line --regexp '^ +evidence .*args: ITEM, --list, --allow-realbox, --help'
}

@test "#513: bare just verify lists the realbox comment tag option" {
    _just verify
    assert_success
    assert_line --regexp '^ +realbox .*--comment-tag'
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

@test "just test changed forwards --changed and every argument verbatim" {
    _stub_scripts
    _just test changed --base main
    assert_success
    assert_equal "$(_stub_calls)" "test.sh --changed --base main"
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

@test "#702: structure documents every public recipe and alias of every root mod" {
    run _command_row_gaps "${REPO_ROOT}"
    assert_success
}

@test "#702: command-table check flags an undocumented recipe with a dependency" {
    mkdir -p "${COPY}/doc"
    cp "${REPO_ROOT}/doc/structure.md" "${COPY}/doc/structure.md"
    cat >>"${COPY}/script/box/justfile.box" <<'EOF'

# Probe documentation coverage for a recipe with a dependency.
deps-probe: status
    @true
EOF
    run _command_row_gaps "${COPY}"
    assert_failure
    assert_line 'missing command row: just box deps-probe'
}

@test "#702: command-table check flags every recipe of an added root mod" {
    mkdir -p "${COPY}/doc" "${COPY}/script/extra"
    cp "${REPO_ROOT}/doc/structure.md" "${COPY}/doc/structure.md"
    cat >>"${COPY}/justfile" <<'EOF'

# Extra actions for documentation coverage.
mod? extra 'script/extra/justfile.extra'
EOF
    cat >"${COPY}/script/extra/justfile.extra" <<'EOF'
set working-directory := '../..'

default:
    @just --justfile script/extra/justfile.extra --list

run *args:
    @true
EOF
    run _command_row_gaps "${COPY}"
    assert_failure
    assert_line 'missing command row: just extra'
    assert_line 'missing command row: just extra run'
}

@test "#561: structure renders every public just command row inside a table" {
    run awk '
        /^\| 指令 \| 實際執行 \|$/ { header = 1; next }
        header && /^\|[-: ]+\|[-: ]+\|$/ { table = 1; header = 0; next }
        /^\| `just/ {
            rows++
            if (!table) {
                print "command row outside a table at line " NR ": " $0
                invalid = 1
            }
        }
        !/^\|/ { table = 0; header = 0 }
        END { exit (invalid || !rows) }
    ' "${REPO_ROOT}/doc/structure.md"
    assert_success
}

@test "#702: structure directory tree lists the verify namespace and its scripts" {
    run sed -n '/^│   ├── verify\//,/^│   └── box\//p' "${REPO_ROOT}/doc/structure.md"
    assert_success
    assert_output --partial 'justfile.verify'
    local _script
    for _script in "${REPO_ROOT}"/script/verify/*.sh; do
        assert_output --partial "${_script##*/}"
    done
}

@test "#446: README and structure describe an independent HOME fixed at box creation" {
    local _doc
    for _doc in README.md doc/structure.md; do
        run grep -F '獨立 HOME' "${REPO_ROOT}/${_doc}"
        assert_success
        run grep -E '[~]/<盒名>-box' "${REPO_ROOT}/${_doc}"
        assert_success
        run grep -F '容器建立後要換 HOME 只能刪盒重建' "${REPO_ROOT}/${_doc}"
        assert_success
        run grep -E '共用的 HOME|尚未實作.*#198.*#199' "${REPO_ROOT}/${_doc}"
        assert_failure
    done
}

@test "#446: README and structure describe the Ghostty command through the quoted entry wrapper" {
    local _doc
    for _doc in README.md doc/structure.md; do
        run grep -F "'<repo>/script/box/enter.sh' --distrobox '<distrobox>' --box '" "${REPO_ROOT}/${_doc}"
        assert_success
        assert_output --partial '已 quote 的絕對路徑'
        run grep -F "'<distrobox>' enter <盒>" "${REPO_ROOT}/${_doc}"
        assert_failure
    done
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

@test "just box setup --auto-enter no --terminal ghostty --box <name with spaces> keeps argv boundaries (argc 6)" {
    _stub_scripts
    _just box setup --auto-enter no --terminal ghostty --box "my box"
    assert_success
    assert_equal "$(_stub_calls)" "setup.sh --auto-enter no --terminal ghostty --box my\\ box"
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
    for _pair in 'lint-system-acceptance=lint system acceptance' 'test-matrix=matrix' \
        'test-integration=integration'; do
        _gate="${_pair%%=*}"
        _tier="${_pair#*=}"
        run grep -A1 -E "^ +- gate: ${_gate}$" "${_yml}"
        assert_success
        assert_line --regexp "^ +tier: ${_tier}$"
    done
    run grep -E '^ +run: just |^ +worktool-verify:local -c ' "${_yml}"
    assert_success
    # A gate leg runs each of its tiers as `just test <tier>` (#841).
    run grep -E 'just test "\$\{tier\}"' "${_yml}"
    assert_success
    run grep -E '^ +run: just |^ +worktool-verify:local -c |just test "\$\{tier\}"' "${_yml}"
    assert_success
    assert_line --regexp '^ +run: just test system-real$'
    # The unit tier runs as weighted shards of the same recipe (#831).
    assert_line --regexp '^ +run: just test unit --shard \$\{\{ matrix\.shard \}\}/\$\{\{ matrix\.shards \}\}$'
    # Milestone acceptance drives just verify inside the real-tool container.
    assert_line --regexp "^ +worktool-verify:local -c 'just verify all'$"
    assert_line --regexp '^ +run: just test verify-env$'
    # Exactly those five invocations: no gate bypasses the grammar.
    assert_equal "${#lines[@]}" 5
}

@test "just agent lists the Codex launcher without starting it" {
    _just agent
    assert_success
    assert_equal "$(_listed_names)" "codex default "
}

# Compare the documented namespace contract with just's parsed module interface.
_structure_namespace_gaps() {
    local root="$1" dump
    if ! dump=$(just --justfile "${root}/justfile" --dump --dump-format json); then
        printf 'namespace rules: just --dump failed\n' >&2
        return 1
    fi
    jq -er --arg root "$root" \
        --rawfile structure "${root}/doc/structure.md" \
        --rawfile design "${root}/doc/design.md" \
        -f "${REPO_ROOT}/test/helper/namespace_rules.jq" <<<"$dump"
}

@test "#724: structure namespace rules match module defaults, help and working directories" {
    run _structure_namespace_gaps "${REPO_ROOT}"
    assert_success
}

_copy_namespace_docs() {
    mkdir -p "${COPY}/doc"
    cp "${REPO_ROOT}/doc/structure.md" "${REPO_ROOT}/doc/design.md" "${COPY}/doc/"
}

@test "#724: namespace check rejects module and design drift" {
    local mutation
    for mutation in alias cwd namespace default design; do
        _make_repo_copy
        _copy_namespace_docs
        case "$mutation" in
            alias) printf '\nalias h := help\n' >>"${COPY}/.agents/script/justfile.job" ;;
            cwd) sed -i "s|working-directory := .*|working-directory := '../..'|" "${COPY}/.agents/script/worktree/justfile.worktree" ;;
            namespace)
                printf "\nmod? extra 'script/agent/justfile.agent'\n" >>"${COPY}/justfile"
                ;;
            default)
                sed -i 's|@just --justfile.*--list|@echo changed|' "${COPY}/script/agent/justfile.agent"
                ;;
            design) sed -i "s/\`job\` 有 \`help\`/\`job\` 有 \`help\`(alias \`h\`)/" "${COPY}/doc/design.md" ;;
        esac
        run _structure_namespace_gaps "${COPY}"
        assert_failure
        if [[ "$mutation" == design ]]; then
            assert_output --partial 'namespace rules: modules differ from design rule 5'
        else
            assert_output --partial 'namespace rules: structure table differs from modules'
        fi
    done
}

@test "#726: README and root header describe six namespaces and only bare test runs all" {
    run grep -F "裸 \`just\` 列出六個 namespaces(\`test\`、\`box\`、\`verify\`、\`agent\`、\`worktree\`、\`job\`)" "${REPO_ROOT}/README.md"
    assert_success
    run grep -F "只有裸 \`just test\` 跑全部測試,其他 namespace 的裸指令只列清單" "${REPO_ROOT}/README.md"
    assert_success
    run grep -F 'test, box, verify, agent, worktree, job' "${REPO_ROOT}/justfile"
    assert_success
    run grep -F "Only bare \`just test\` runs everything CI runs; other bare namespaces list" "${REPO_ROOT}/justfile"
    assert_success
}

@test "#726: README command table includes matrix in all tests and tier selection" {
    run grep -E "^\| \`just test\` \|" "${REPO_ROOT}/README.md"
    assert_success
    assert_output --partial 'lint、unit、matrix、integration、system、acceptance、system-real'
    run grep -E "^\| \`just test unit\`" "${REPO_ROOT}/README.md"
    assert_success
    assert_output --partial "\`matrix\`"
}

@test "#726: README command table documents box bench metrics and options" {
    run grep -E "^\| \`just box bench " "${REPO_ROOT}/README.md"
    assert_success
    assert_output --partial 'enter、shell、inbox'
    assert_output --partial 'min / median / max'
    assert_output --partial '--max-ms'
    assert_output --partial '--max-wait'
    assert_output --partial '預設 60'
    assert_output --partial "\`CI\` 時 120"
}

@test "#726: README command table distinguishes verify listing, all and opt-in realbox" {
    run grep -E "^\| \`just verify\`" "${REPO_ROOT}/README.md"
    assert_success
    assert_output --partial '只列清單'
    run grep -E "^\| \`just verify all" "${REPO_ROOT}/README.md"
    assert_success
    assert_output --partial '非實機'
    run grep -E "^\| \`just verify <" "${REPO_ROOT}/README.md"
    assert_success
    assert_output --partial 'ui、gate、setup、diagram、evidence'
    run grep -E "^\| \`just verify realbox" "${REPO_ROOT}/README.md"
    assert_success
    assert_output --partial '--allow-real-box'
}
