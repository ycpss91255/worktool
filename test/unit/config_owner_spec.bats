#!/usr/bin/env bats
# test/unit/config_owner_spec.bats - no module but lib/config.sh reaches
# the state file, over every entry point the parsers expose and every module
# in the source graph that names a public config_* function or
# XDG_CONFIG_HOME in a non-comment line (issue #199 rounds 6-10).
#
# What is checked, and nothing more:
#   - lib/config.sh honours a test-only WORKTOOL_CONFIG_FILE, pointed at a
#     random path; the DEFAULT location ($XDG_CONFIG_HOME/worktool/config)
#     is a trap, one run per form:
#       poison  a file whose values would show up in the output, or refuse
#               the run, if read; its bytes and directory must not change;
#       fifo    a named pipe: opening it (to read or write) blocks, so the
#               run times out; it must still be a pipe after.
#   - the runs are ONE table (_runs). Entry points: every verb of
#     script/box/justfile.box whose script's source graph reaches
#     lib/config.sh (test/helper/graph.bash follows `source` lines), and
#     every option label of that script's argument loop, in both
#     `--opt v` and `--opt=v` forms; plus setup's restore paths and the fake
#     container manager in both states (no box / an existing box). Guards
#     fail when a verb or a label is missing from the table.
#   - labels are the whole option surface because every script under
#     script/ whose source graph reaches lib/config.sh reads its arguments
#     in ONE `while [[ $# -gt 0 ]]; do case "$1"`
#     loop: a guard fails on a positional parameter used outside that loop
#     by the entry function (or the parser it hands "$@" to), on a test of
#     $1 other than the case, and on positional use at the top level.
# test/unit/config_mutation_spec plants a rogue path-builder in every module
# of the source graph that names a public config_* function or
# XDG_CONFIG_HOME in a non-comment line, and requires these cases to catch
# each one; modules that name neither are not checked.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/graph"

bats_require_minimum_version 1.5.0

# script|prep|args - one run per row, each in both manager states and both
# trap forms. `prep` names a setup run made first (see _prep). @DBX@ is the
# fake distrobox, @BOX@ the box HOME used by assemble.
_runs() {
    printf '%s\n' \
        'setup||' \
        'setup||--auto-enter yes --terminal ghostty --tmux host --box dev --distrobox @DBX@' \
        'setup||--auto-enter=yes --terminal=ghostty --tmux=inside --box=work --distrobox=@DBX@' \
        'setup||--terminal none --tmux host' \
        'setup||--dry-run --tmux host' \
        'setup||-h' \
        'setup||--help' \
        'setup|ghostty-host|--auto-enter no' \
        'setup|ghostty-inside|--auto-enter=no' \
        'setup|none-host|--auto-enter no --dry-run' \
        'assemble||' \
        'assemble||--file box/dev.ini --home @BOX@' \
        'assemble||--file=box/dev.ini --home=@BOX@' \
        'assemble||--dry-run --home @BOX@' \
        'assemble||-h' \
        'assemble||--help' \
        'status||' \
        'status|ghostty-host|' \
        'status||-h' \
        'status||--help' \
        'enter||' \
        'enter||--box dev --distrobox @DBX@ --timeout 30 -- true' \
        'enter||--box=dev --distrobox=@DBX@ --timeout=30' \
        'enter|ghostty-inside|' \
        'enter||-h' \
        'enter||--help'
}

# The verbs of script/box/justfile.box, one per line.
_verbs() {
    sed -n 's/^\([a-z][a-z-]*\) \*args:$/\1/p' "${REPO_ROOT}/script/box/justfile.box"
}

# 0 when the source graph of verb $1's script reaches lib/config.sh.
_reaches_config() {
    local _mods
    _mods="$(graph_modules "${REPO_ROOT}" "script/box/$1.sh")" || return 1
    grep -qx 'lib/config.sh' <<<"${_mods}"
}

# The options script $1's parser accepts, one per line: every `case` label
# starting with `-` in the script (the usage text is flush left, labels are
# indented), `--x=*` written `--x=`.
_parser_options() {
    grep -oE '^[[:space:]]+-[-a-z|=*]+\)' "${REPO_ROOT}/script/box/$1.sh" \
        | tr -d ' )' | tr '|' '\n' | sed 's/=\*$/=/' | sort -u
}

# Positional-parameter use in script $1 (a path) outside its ONE argument
# loop, one line per violation. The entry function is the one the run guard
# calls with "$@"; the parsers are it and the functions it hands "$@" to.
# Comments and heredoc bodies are skipped; other functions get their own
# arguments and are not looked at.
_parser_violations() {
    awk -f <(_parser_awk) "$1" "$1"
}

_parser_awk() {
    cat <<'AWK'
function heredoc_start(l,   d) {
    if (match(l, /<<-?[ ]*['"]?[A-Za-z_]+['"]?/)) {
        d = substr(l, RSTART + 2, RLENGTH - 2); gsub(/[^A-Za-z_]/, "", d); return d
    }
    return ""
}
FNR == NR {
    if (hd != "") { if ($0 == hd) hd = ""; next }
    if ($0 ~ /^[[:space:]]*#/) next
    if ($0 ~ /^if \[\[ "\$\{BASH_SOURCE\[0\]:-\}" == "\$\{0:-\}" \]\]; then$/) { guard = 1; next }
    if (guard == 1) { split($0, w, " "); entry = w[1]; guard = 2 }
    if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/) { fn = $0; sub(/\(.*/, "", fn); body[fn] = "" }
    if (fn != "") body[fn] = body[fn] "\n" $0
    if ($0 ~ /^\}/ || ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ && $0 ~ /\}[[:space:]]*$/)) fn = ""
    hd = heredoc_start($0)
    next
}
FNR == 1 {
    parser[entry] = 1
    n = split(body[entry], lines, "\n")
    for (i = 1; i <= n; i++) {
        l = lines[i]
        while (match(l, /[A-Za-z_][A-Za-z0-9_]* "\$@"/)) {
            c = substr(l, RSTART, RLENGTH); sub(/ .*/, "", c)
            if (c in body) parser[c] = 1
            l = substr(l, RSTART + RLENGTH)
        }
    }
    hd = ""; fn = ""; loops = 0
}
{
    if (hd != "") { if ($0 == hd) hd = ""; next }
    if ($0 ~ /^[[:space:]]*#/) next
    line = $0
    starts = ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/)
    if (starts) { fn = $0; sub(/\(.*/, "", fn) }
    if (fn == "") {
        if (line ~ /^if \[\[ "\$\{BASH_SOURCE\[0\]:-\}"/) { hd = heredoc_start($0); next }
        if (line ~ ("^[[:space:]]+" entry " \"\\$@\"$")) next
        if (line ~ /\$[1-9#*@]|\$\{([1-9]|#\}|[*@])/) print FILENAME ":" FNR ": positional parameter at the top level: " line
    } else if (fn in parser) {
        if (line ~ /while \[\[ \$# -gt 0 \]\]/) {
            loops++; inloop = 1; ind = line; sub(/[^ ].*/, "", ind)
        } else if (inloop && line ~ ("^" ind "done")) {
            inloop = 0
        } else {
            if ((line ~ /\[\[|\[ |(^|[^A-Za-z_])test /) && (line ~ /\$1([^0-9]|$)|\$\{1[^0-9]/))
                print FILENAME ":" FNR ": $1 tested outside the case of the argument loop: " line
            if (!inloop && line ~ /case "\$1" in/)
                print FILENAME ":" FNR ": case on $1 outside the argument loop: " line
            if (!inloop) {
                l = line; gsub(/"\$@"/, "", l)
                if (l ~ /\$[1-9#*@]|\$\{([1-9]|#\}|[*@])/ || l ~ /(^|[^A-Za-z_])shift([^A-Za-z_]|$)/)
                    print FILENAME ":" FNR ": positional parameter outside the argument loop: " line
            }
        }
    }
    if ($0 ~ /^\}/ || (starts && $0 ~ /\}[[:space:]]*$/)) { fn = ""; inloop = 0 }
    hd = heredoc_start($0)
}
END { if (loops > 1) print FILENAME ": " loops " argument loops (one is allowed)" }
AWK
}

# The options the table uses for script $1, in the same form.
_table_options() {
    local _s _p _a _w
    local -a _ws
    while IFS='|' read -r _s _p _a; do
        [[ "${_s}" == "$1" ]] || continue
        read -r -a _ws <<<"${_a}"
        for _w in "${_ws[@]}"; do
            [[ "${_w}" == -* ]] || continue
            [[ "${_w}" == *=* ]] && _w="${_w%%=*}="
            printf '%s\n' "${_w}"
        done
    done < <(_runs)
}

setup() {
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CONFIG_HOME DBX_CONTAINER_CUSTOM_HOME FAKE_BOX_HOME
    mkdir -p "${HOME}"
    DEFAULT_DIR="${HOME}/.config/worktool"
    STATE="$(mktemp -d "${BATS_TEST_TMPDIR}/state.XXXXXX")/state"
    export WORKTOOL_CONFIG_FILE="${STATE}"

    # distrobox and the container manager, faked: `ps -a` lists `dev` when
    # FAKE_BOX_HOME is set (an existing box), `inspect` reports that HOME.
    MOCKBIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${MOCKBIN}"
    printf '#!/bin/sh\nexit 0\n' >"${MOCKBIN}/distrobox"
    cat >"${MOCKBIN}/docker" <<'EOF'
#!/bin/sh
case "$1" in
    ps) [ -n "${FAKE_BOX_HOME:-}" ] && echo dev; exit 0 ;;
    inspect) printf '%s\n' --name dev --home "${FAKE_BOX_HOME}"; exit 0 ;;
esac
exit 2
EOF
    chmod +x "${MOCKBIN}/distrobox" "${MOCKBIN}/docker"
    PATH="${MOCKBIN}:${PATH}"
    export PATH DBX_CONTAINER_MANAGER=docker
    BOX_HOME="${BATS_TEST_TMPDIR}/box-home"
}

# Lay the trap of form $1 at the default location.
_trap() {
    rm -rf "${DEFAULT_DIR}"
    mkdir -p "${DEFAULT_DIR}"
    if [[ "$1" == fifo ]]; then
        mkfifo "${DEFAULT_DIR}/config"
    else
        printf '%s\n' '# POISON: nothing may read or write this file' \
            'tmux=POISON' 'tmux.source=user' 'box=poison' 'box.source=user' \
            'home=/poison-home' 'home.source=user' 'link=.poison' >"${DEFAULT_DIR}/config"
        cp "${DEFAULT_DIR}/config" "${BATS_TEST_TMPDIR}/poison.orig"
    fi
}

# Fail naming run $2 when the trap of form $1 was touched.
_check_trap() {
    local _ls
    _ls="$(ls -A "${DEFAULT_DIR}")"
    [[ "${_ls}" == config ]] || fail "$2: the default directory changed: ${_ls}"
    if [[ "$1" == fifo ]]; then
        [[ -p "${DEFAULT_DIR}/config" ]] || fail "$2: the default location was replaced"
    else
        cmp -s -- "${BATS_TEST_TMPDIR}/poison.orig" "${DEFAULT_DIR}/config" \
            || fail "$2: the default location was written"
    fi
}

# Run script $1 with the words of $2 (placeholders expanded); output in
# RUN_OUT, status in RUN_RC. A run that opens the fifo blocks: 124.
_script() {
    local -a _w
    local _a="${2//@DBX@/${MOCKBIN}/distrobox}"
    _a="${_a//@BOX@/${BOX_HOME}}"
    read -r -a _w <<<"${_a}"
    RUN_RC=0
    RUN_OUT="$(cd "${REPO_ROOT}" && timeout 30 "${REPO_ROOT}/script/box/$1.sh" "${_w[@]}" 2>&1)" \
        || RUN_RC=$?
}

# The setup run made before a row (restore paths need a written profile).
_prep() {
    case "$1" in
        '') return 0 ;;
        ghostty-host) _script setup '--terminal ghostty --tmux host' ;;
        ghostty-inside) _script setup '--terminal ghostty --tmux inside' ;;
        none-host) _script setup '--terminal none --tmux host' ;;
    esac
}

# Every row of script $1, in both manager states and both trap forms.
_owner_runs() {
    local _s _p _a _state _form _name
    local -a _states=(none existing)
    while IFS='|' read -r _s _p _a; do
        [[ "${_s}" == "$1" ]] || continue
        for _state in "${_states[@]}"; do
            for _form in poison fifo; do
                _name="${_s} ${_a:-<no args>} [prep ${_p:-none}, box ${_state}, ${_form}]"
                rm -f "${STATE}"
                printf '%s\n' '# mine' 'link=.aws' >"${STATE}"
                _trap "${_form}"
                if [[ "${_state}" == existing ]]; then
                    export FAKE_BOX_HOME="${BOX_HOME}"
                else
                    unset FAKE_BOX_HOME
                fi
                RUN_RC=0
                _prep "${_p}"
                [[ "${RUN_RC}" -ne 124 ]] || fail "${_name}: prep opened the default location"
                _script "${_s}" "${_a}"
                [[ "${RUN_RC}" -ne 124 ]] || fail "${_name}: opened the default location (blocked on the fifo)"
                [[ "${RUN_OUT}" != *[Pp][Oo][Ii][Ss][Oo][Nn]* ]] \
                    || fail "${_name}: read the default location: ${RUN_OUT}"
                _check_trap "${_form}" "${_name}"
            done
        done
    done < <(_runs)
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "drift guard: every verb that can reach the state file has rows in the table" {
    local _v _missing=""
    while IFS= read -r _v; do
        _reaches_config "${_v}" || continue
        _runs | grep -q "^${_v}|" || _missing+=" ${_v}"
    done < <(_verbs)
    [[ -z "${_missing}" ]] || fail "verbs missing from the table:${_missing}"
    # The guard sees the verbs it should: setup, assemble and status reach
    # the state file; bench does not.
    run _verbs
    assert_line setup
    _reaches_config setup
    ! _reaches_config bench || fail "bench is expected not to reach the state file"
}

@test "drift guard: every option of every parser is used by some row" {
    local _s _o _missing=""
    local -a _scripts=()
    while IFS= read -r _s; do
        _reaches_config "${_s}" && _scripts+=("${_s}")
    done < <(_verbs)
    for _s in "${_scripts[@]}"; do
        while IFS= read -r _o; do
            _table_options "${_s}" | grep -qxF -- "${_o}" || _missing+=" ${_s}:${_o}"
        done < <(_parser_options "${_s}")
    done
    [[ -z "${_missing}" ]] || fail "parser options missing from the table:${_missing}"
    run _parser_options setup
    assert_line -- "--distrobox="
    assert_line -- "-h"
}

@test "structure guard: every script reaching config reads its arguments only in its one argument loop" {
    local _f _mods _out=""
    for _f in "${REPO_ROOT}"/script/*/*.sh; do
        _mods="$(graph_modules "${REPO_ROOT}" "${_f#"${REPO_ROOT}"/}")" \
            || fail "unresolved source graph of ${_f}"
        grep -qx 'lib/config.sh' <<<"${_mods}" || continue
        _out+="$(_parser_violations "${_f}")"
    done
    [[ -z "${_out}" ]] || fail "argument use outside the argument loop: ${_out}"
}

@test "structure guard: it catches an option read outside the loop, at the top level, or a second loop" {
    local _f="${BATS_TEST_TMPDIR}/rogue.sh"
    cat >"${_f}" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == --early ]] && echo early
rogue_run() {
    if [[ "$1" == --audit ]]; then echo audit; fi
    _parse "$@"
}
_parse() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ok) : ;;
            *) [[ "$1" == --late ]] && echo late ;;
        esac
        shift
    done
    while [[ $# -gt 0 ]]; do shift; done
}
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    rogue_run "$@"
fi
EOF
    run _parser_violations "${_f}"
    assert_line --partial "rogue.sh:2: positional parameter at the top level"
    assert_line --partial "rogue.sh:4: \$1 tested outside the case"
    assert_line --partial "rogue.sh:11: \$1 tested outside the case"
    assert_line --partial "2 argument loops (one is allowed)"
}

@test "parser guard ignores unrelated scripts and rejects a reachable rogue parser" {
    local _tree="${BATS_TEST_TMPDIR}/repo" _filter='^structure guard: every script'
    mkdir -p "${_tree}"
    cp -R "${REPO_ROOT}/lib" "${REPO_ROOT}/script" "${REPO_ROOT}/test" "${_tree}/"
    printf '%s\n' 'echo "$1"' >"${_tree}/script/test/unrelated.sh"
    run bats --filter "${_filter}" "${_tree}/test/unit/config_owner_spec.bats"
    assert_success

    printf '%s\n' 'source "${LIB_DIR}/config.sh"' 'echo "$1"' \
        >"${_tree}/script/test/unrelated.sh"
    run bats --filter "${_filter}" "${_tree}/test/unit/config_owner_spec.bats"
    assert_failure
    assert_output --partial 'unrelated.sh:2: positional parameter at the top level'
}

@test "owner: every setup row reads and writes only the state file lib/config.sh names" {
    _owner_runs setup
}

@test "owner: every assemble row reads and writes only the state file lib/config.sh names" {
    _owner_runs assemble
}

@test "owner: every status row reads and writes only the state file lib/config.sh names" {
    _owner_runs status
}

@test "owner: every enter row reads and writes only the state file lib/config.sh names" {
    _owner_runs enter
}

@test "owner: setup, assemble and status act on the named state file (effects)" {
    _trap poison
    printf '%s\n' '# mine' 'link=.aws' >"${STATE}"
    run "${REPO_ROOT}/script/box/setup.sh" --tmux host
    assert_success
    assert_line "[INFO] wrote: ${STATE}"
    run "${REPO_ROOT}/script/box/assemble.sh" --home "${BOX_HOME}"
    assert_success
    assert_line "[INFO] recorded box home in ${STATE}"
    run "${REPO_ROOT}/script/box/status.sh"
    assert_success
    assert_line "config: ${STATE}"
    assert_line "tmux: host (user)"
    assert_line "link: ${BOX_HOME}/.aws -> ${HOME}/.aws (missing source)"
    assert_line "home: ${BOX_HOME} (user)"
    run grep -cxE '# mine|link=\.aws|tmux=host|tmux\.source=user|home=.*/box-home|home\.source=user' "${STATE}"
    assert_output "6"
    _check_trap poison effects
}

@test "owner: the validators (lib/enter.sh, lib/home.sh) judge the named state file" {
    _trap poison
    printf '%s\n' 'tmux=sideways' >"${STATE}"
    run "${REPO_ROOT}/script/box/setup.sh"
    assert_failure 1
    assert_line "[ERROR] ${STATE}: invalid value 'sideways' for tmux (expected inside|host)"
    printf '%s\n' 'home=relative' 'home.source=user' >"${STATE}"
    run "${REPO_ROOT}/script/box/assemble.sh"
    assert_failure 1
    assert_line "[ERROR] ${STATE}: invalid value 'relative' for home (expected an absolute path)"
    _check_trap poison validators
}
