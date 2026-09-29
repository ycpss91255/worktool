#!/usr/bin/env bats
# test/unit/config_owner_spec.bats - only lib/config.sh reaches the state
# file, proven by BEHAVIOUR over every verb and option (issue #199 rounds
# 6-7).
#
# A text search cannot prove that a bash module never builds the path
# (`p=worktool; "$(config_xdg_dir)/$p/config"` passes any deny-list), and a
# few hand-picked runs leave branches unexercised. So:
#   - lib/config.sh honours a test-only WORKTOOL_CONFIG_FILE, pointed at a
#     random path; the DEFAULT location ($XDG_CONFIG_HOME/worktool/config)
#     is a trap, in two forms, one run each:
#       poison  a file whose values would show up in any output, or refuse
#               the run, if anything read them; its bytes and directory
#               must not change (nothing may write there);
#       fifo    a named pipe: anything that opens it - to read or to write -
#               blocks, so the run times out; it must still be a pipe after.
#   - the runs are ONE table (_runs): every verb whose script can reach the
#     state file (derived from script/box/justfile.box), every option of its
#     own option parser (derived from the script source), setup's restore
#     paths (auto-enter no after a profile was written), and the fake
#     container manager in both states (no box / an existing box). Drift
#     guards fail when a verb or a parser option is missing from the table.
# test/unit/config_mutation_spec plants a rogue path-builder in every module
# that touches the state file and requires these cases to catch each one.

load "${BATS_TEST_DIRNAME}/../helper/common"

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
        'status||--help'
}

# The verbs of script/box/justfile.box, one per line.
_verbs() {
    sed -n 's/^\([a-z][a-z-]*\) \*args:$/\1/p' "${REPO_ROOT}/script/box/justfile.box"
}

# 0 when script $1 can reach the state file: it sources lib/config.sh, or a
# library that sources it.
_reaches_config() {
    grep -qE 'source "\$\{LIB_DIR\}/(config|enter|home|link)\.sh"' "${REPO_ROOT}/script/box/$1.sh"
}

# The options script $1's parser accepts, one per line: every `case` label
# starting with `-` in the script (the usage text is flush left, labels are
# indented), `--x=*` written `--x=`.
_parser_options() {
    grep -oE '^[[:space:]]+-[-a-z|=*]+\)' "${REPO_ROOT}/script/box/$1.sh" \
        | tr -d ' )' | tr '|' '\n' | sed 's/=\*$/=/' | sort -u
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
    for _s in setup assemble status; do
        while IFS= read -r _o; do
            _table_options "${_s}" | grep -qxF -- "${_o}" || _missing+=" ${_s}:${_o}"
        done < <(_parser_options "${_s}")
    done
    [[ -z "${_missing}" ]] || fail "parser options missing from the table:${_missing}"
    run _parser_options setup
    assert_line -- "--distrobox="
    assert_line -- "-h"
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
