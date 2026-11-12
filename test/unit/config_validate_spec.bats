#!/usr/bin/env bats
# test/unit/config_validate_spec.bats - a bare key is that key with an empty
# value, for every judge of the state file (issue #199 rounds 10-11).
#
# lib/config.sh's format: a line without `=` is a bare key with an empty
# value. So every judged key gets the same verdict for a bare `<key>` line
# as for `<key>=`. What is checked, and nothing more:
#   - the matrix: every judged key x {bare, `key=`, whitespace-only value, a
#     valid value};
#   - the judges of a key are derived, not listed: every script under
#     script/ that calls the key's reader - enter_config_check for the
#     decisions and their `.source`, home_config_check for home /
#     home.source, link_entries for link - directly or through functions of
#     the modules in its source graph (test/helper/graph.bash graph_judges),
#     derived once per file in setup_file for each reader and shared by the
#     cases; a failed or empty derivation fails every case that uses it;
#     a new script that calls a reader is both derived and run through
#     the matrix (a fixture tree, issue #774);
#   - a verdict is the exit status, stdout and stderr; bare and `key=` must
#     give byte-identical stdout and stderr files (cmp) and the same status;
#     bare, empty and blank are refused (link: warned about and skipped), a
#     valid value is accepted (link: linked).
# The judged-key matrix is one generated case per key (issue #859), so the
# keys run in parallel; together they are the whole matrix.

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/graph"

# The readers whose callers are the judges.
READERS=(enter_config_check home_config_check link_entries)

# graph_judges, run in a plain child bash: under bats' DEBUG trap the
# helper's per-line bash loops are many times slower. Every call over this
# repo is traced, so a case can check that the derivation ran once per
# reader in this file.
graph_judges() {
    [[ "$1" != "${REPO_ROOT}" ]] || printf '%s\n' "$2" >>"${BATS_FILE_TMPDIR}/derivations"
    bash -c 'source "$1" && shift && graph_judges "$@"' _ "${BATS_TEST_DIRNAME}/../helper/graph.bash" "$@"
}

# Derive the judges of every reader of tree $1 into directory $2: `<reader>`
# holds the scripts, `<reader>.rc` the derivation's status. Never fails
# itself, so a failed derivation reaches the cases as a failure, not a skip.
_derive_judges() {
    local _r _rc
    mkdir -p "$2"
    for _r in "${READERS[@]}"; do
        _rc=0
        graph_judges "$1" "${_r}" >"$2/${_r}" 2>"$2/${_r}.err" || _rc=$?
        printf '%s\n' "${_rc}" >"$2/${_r}.rc"
    done
}

setup_file() {
    _derive_judges "${REPO_ROOT}" "${BATS_FILE_TMPDIR}/judges"
}

setup() {
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CONFIG_HOME FAKE_BOX_HOME
    mkdir -p "${HOME}"
    CONFIG="${HOME}/.config/worktool/config"
    BOX="${BATS_TEST_TMPDIR}/box"
    # distrobox and a container manager with no box: setup resolves
    # distrobox, assemble runs for real.
    MOCKBIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${MOCKBIN}"
    printf '#!/bin/sh\nexit 0\n' >"${MOCKBIN}/distrobox"
    cat >"${MOCKBIN}/docker" <<'EOF'
#!/bin/sh
[ "$1" = ps ] && exit 0
exit 2
EOF
    chmod +x "${MOCKBIN}/distrobox" "${MOCKBIN}/docker"
    PATH="${MOCKBIN}:${PATH}"
    export PATH DBX_CONTAINER_MANAGER=docker
}

# The judged keys: `key|reader|valid value|companion line` (the companion
# keeps the key's pair rule satisfied, so the verdict is about the key).
_keys() {
    printf '%s\n' \
        'auto-enter|enter_config_check|yes|' 'auto-enter.source|enter_config_check|user|' \
        'terminal|enter_config_check|none|' 'terminal.source|enter_config_check|user|' \
        'box|enter_config_check|dev|' 'box.source|enter_config_check|user|' \
        "home|home_config_check|${BATS_TEST_TMPDIR}/box|home.source=user" \
        "home.source|home_config_check|user|home=${BATS_TEST_TMPDIR}/box"
}

# The judges of reader function $1: every script that calls it, as derived
# into directory JUDGES (default: setup_file's). A missing or failed
# derivation, or an empty set, fails the case instead of passing it
# vacuously. It returns explicitly: under `run` errexit is off.
_judges() {
    local _d="${JUDGES:-${BATS_FILE_TMPDIR}/judges}"
    if [[ ! -f "${_d}/$1.rc" || "$(cat "${_d}/$1.rc")" != 0 ]]; then
        fail "cannot derive the judges of $1: $(cat "${_d}/$1.err" 2>/dev/null)"
        return 1
    fi
    if [[ ! -s "${_d}/$1" ]]; then
        fail "no script calls $1"
        return 1
    fi
    cat "${_d}/$1"
}

# The command a judge script of tree TREE (default: this repo) runs as:
# status and assemble as a user would (assemble for real, against the fake
# manager); setup with --dry-run.
_command() {
    case "$1" in
        script/box/setup.sh) printf '%s\n' "${TREE:-${REPO_ROOT}}/$1 --dry-run" ;;
        *) printf '%s\n' "${TREE:-${REPO_ROOT}}/$1" ;;
    esac
}

# The line of form $2 for key $1 (valid value $3).
_line() {
    case "$2" in
        bare)  printf '%s\n' "$1" ;;
        empty) printf '%s=\n' "$1" ;;
        ws)    printf '%s=  \n' "$1" ;;
        valid) printf '%s=%s\n' "$1" "$3" ;;
    esac
}

# Run judge command $2.. on the state file; stdout, stderr and the status
# go to files prefixed $1 (.out .err .rc).
_judge() {
    local _p="$1" _rc=0
    shift
    local -a _cmd
    read -r -a _cmd <<<"$*"
    (cd "${TREE:-${REPO_ROOT}}" && "${_cmd[@]}" >"${_p}.out" 2>"${_p}.err") || _rc=$?
    printf '%s\n' "${_rc}" >"${_p}.rc"
}

# Fail unless forms bare and empty (prefix $1.) gave byte-identical files.
_assert_same() {
    local _x
    for _x in rc out err; do
        cmp -s -- "$1.bare.${_x}" "$1.empty.${_x}" || {
            fail "$2: bare and \`key=\` differ in ${_x}: $(diff "$1.bare.${_x}" "$1.empty.${_x}")"
            return 1
        }
    done
}

# The decision / home matrix over tree $1 with the judges derived into
# directory $2, for the keys of readers $3..: every judge of a key, every
# form, the same checks. It returns at the first failure, so it fails under
# `run` too, where errexit is off.
_value_matrix() {
    local TREE="$1" JUDGES="$2" _k _r _v _c _s _form _p
    local -A _of=()
    shift 2
    # Read here, in this shell, so an empty or failed derivation fails
    # the matrix rather than running no judge.
    for _r in "$@"; do _of[${_r}]="$(_judges "${_r}")" || return 1; done
    mkdir -p "$(dirname -- "${CONFIG}")"
    while IFS='|' read -r _k _r _v _c; do
        [[ -z "${JUDGED_KEY:-}" || "${_k}" == "${JUDGED_KEY}" ]] || continue
        [[ -n "${_of[${_r}]+x}" ]] || continue
        while IFS= read -r _s; do
            _p="${BATS_TEST_TMPDIR}/v.${_k}.${_s##*/}"
            for _form in bare empty ws valid; do
                rm -rf "${BOX}"
                { _line "${_k}" "${_form}" "${_v}"; [[ -z "${_c}" ]] || printf '%s\n' "${_c}"; } >"${CONFIG}"
                _judge "${_p}.${_form}" "$(_command "${_s}")"
            done
            _assert_same "${_p}" "${_k} via ${_s}" || return 1
            if ! { [[ "$(cat "${_p}.empty.rc")" == 1 ]] &&
                grep -qF "[ERROR] ${CONFIG}: invalid value '' for ${_k}" "${_p}.empty.err"; }; then
                fail "${_k} via ${_s}: empty not refused: $(cat "${_p}.empty.err")"
                return 1
            fi
            if ! { [[ "$(cat "${_p}.ws.rc")" == 1 ]] &&
                grep -qF "[ERROR] ${CONFIG}: invalid value '  ' for ${_k}" "${_p}.ws.err"; }; then
                fail "${_k} via ${_s}: whitespace not refused: $(cat "${_p}.ws.err")"
                return 1
            fi
            if [[ "$(cat "${_p}.valid.rc")" != 0 ]]; then
                fail "${_k} via ${_s}: valid value refused: $(cat "${_p}.valid.err")"
                return 1
            fi
        done <<<"${_of[${_r}]}"
    done < <(_keys)
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# Run the same fail-closed matrix for one generated key.
_judge_key() {
    local _row _reader
    _row="$(_keys | awk -F'|' -v k="$1" '$1 == k')"
    [[ -n "${_row}" ]] || { fail "no judged key $1"; return 1; }
    IFS='|' read -r _ _reader _ <<<"${_row}"
    JUDGED_KEY="$1" _value_matrix "${REPO_ROOT}" "${BATS_FILE_TMPDIR}/judges" "${_reader}"
}

# One case per judged key, named "...: <key> via <reader>" (config_mutation
# selects the enter_config_check keys by that suffix).
_KEY_CASE='bare key = empty value: every judged key, every judge, identical bytes; bare, empty and blank refused, valid accepted'
while IFS='|' read -r _gen_k _gen_r _; do
    bats_test_function --description "${_KEY_CASE}: ${_gen_k} via ${_gen_r}" -- _judge_key "${_gen_k}"
done < <(_keys)
unset _gen_k _gen_r

@test "the judged-key matrix has exactly one generated case per judged key" {
    local _k _r _ _n
    while IFS='|' read -r _k _r _; do
        _n="$(bats --count --filter "^${_KEY_CASE//./\\.}: ${_k//./\\.} via ${_r}\$" "${BATS_TEST_FILENAME}")"
        [[ "${_n}" -eq 1 ]] || fail "key ${_k}: ${_n} generated case(s), want 1"
    done < <(_keys)
    _n="$(bats --count --filter "^${_KEY_CASE//./\\.}: " "${BATS_TEST_FILENAME}")"
    assert_equal "${_n}" "$(_keys | wc -l)"
}

@test "bare key = empty value: link, every judge (bare, empty and blank warned about and skipped; a path linked)" {
    local _s _form _p _t='~' _of
    _of="$(_judges link_entries)"
    # assemble reaches link_entries only through link_apply: the derivation
    # must follow that chain.
    grep -qx script/box/assemble.sh <<<"${_of}" \
        || fail "assemble is not derived as a judge of link"
    mkdir -p "$(dirname -- "${CONFIG}")" "${HOME}/.aws"
    while IFS= read -r _s; do
        _p="${BATS_TEST_TMPDIR}/l.${_s##*/}"
        for _form in bare empty ws valid; do
            rm -rf "${BOX}"
            { printf 'home=%s\nhome.source=user\n' "${BOX}"; _line link "${_form}" "${_t}/.aws"; } >"${CONFIG}"
            _judge "${_p}.${_form}" "$(_command "${_s}")"
        done
        _assert_same "${_p}" "link via ${_s}"
        grep -qF "[WARN] link: '' in ${CONFIG} is not a path under \$HOME - skipped" "${_p}.empty.err" \
            || fail "link via ${_s}: empty not warned about: $(cat "${_p}.empty.err")"
        grep -qF "[WARN] link: '  ' in ${CONFIG} is not a path under \$HOME - skipped" "${_p}.ws.err" \
            || fail "link via ${_s}: whitespace not warned about: $(cat "${_p}.ws.err")"
        cat "${_p}.valid.out" "${_p}.valid.err" | grep -qF "${BOX}/.aws -> ${HOME}/.aws" \
            || fail "link via ${_s}: the path was not linked: $(cat "${_p}.valid.out" "${_p}.valid.err")"
    done <<<"${_of}"
}

@test "a failed, empty or missing derivation fails the case that uses it" {
    local _d="${BATS_TEST_TMPDIR}/judges"
    mkdir -p "${_d}"
    printf '1\n' >"${_d}/enter_config_check.rc"
    printf 'unresolved source line\n' >"${_d}/enter_config_check.err"
    : >"${_d}/enter_config_check"
    JUDGES="${_d}" run _judges enter_config_check
    assert_failure
    assert_output --partial 'cannot derive the judges of enter_config_check: unresolved source line'
    printf '0\n' >"${_d}/home_config_check.rc"
    : >"${_d}/home_config_check"
    JUDGES="${_d}" run _judges home_config_check
    assert_failure
    assert_output --partial 'no script calls home_config_check'
    rm "${_d}/home_config_check"
    JUDGES="${_d}" run _judges home_config_check
    assert_failure
    assert_output --partial 'no script calls home_config_check'
    JUDGES="${_d}" run _judges link_entries
    assert_failure
    assert_output --partial 'cannot derive the judges of link_entries'
}

@test "an unresolved source graph fails the matrix without running a partial judge list" {
    local _tree="${BATS_TEST_TMPDIR}/repo" _d="${BATS_TEST_TMPDIR}/judges" _log="${BATS_TEST_TMPDIR}/ran"
    mkdir -p "${_tree}/script/a" "${_tree}/script/z"
    cat >"${_tree}/script/a/probe.sh" <<'EOF2'
#!/usr/bin/env bash
probe_run() { enter_config_check; touch "${PROBE_LOG}"; }
probe_run
EOF2
    chmod +x "${_tree}/script/a/probe.sh"
    printf 'source "$%s/dependency.sh"\n' UNKNOWN >"${_tree}/script/z/broken.sh"
    _derive_judges "${_tree}" "${_d}"
    PROBE_LOG="${_log}" run _value_matrix "${_tree}" "${_d}" enter_config_check
    assert_failure
    assert_output --partial 'cannot derive the judges of enter_config_check'
    [[ ! -e "${_log}" ]] || fail 'matrix ran a partial judge list'
}

@test "a new script that calls a reader is derived as its judge" {
    local _tree="${BATS_TEST_TMPDIR}/repo" _d="${BATS_TEST_TMPDIR}/judges"
    mkdir -p "${_tree}/script/x" "${_tree}/lib"
    printf '%s\n' 'enter_config_check() { :; }' >"${_tree}/lib/enter.sh"
    cat >"${_tree}/script/x/probe.sh" <<'EOF2'
source "${SCRIPT_DIR}/../../lib/enter.sh"
probe_run() { enter_config_check; }
EOF2
    _derive_judges "${_tree}" "${_d}"
    JUDGES="${_d}" run _judges enter_config_check
    assert_success
    assert_output 'script/x/probe.sh'
    JUDGES="${_d}" run _judges link_entries
    assert_failure
    assert_output --partial 'no script calls link_entries'
}

@test "a new script that calls a reader is run through the matrix" {
    local _tree="${BATS_TEST_TMPDIR}/repo" _d="${BATS_TEST_TMPDIR}/judges" _log="${BATS_TEST_TMPDIR}/probe.log"
    mkdir -p "${_tree}/script/x" "${_tree}/lib"
    printf '%s\n' 'enter_config_check() { :; }' >"${_tree}/lib/enter.sh"
    # A judge that accepts every value, and records each state file it saw.
    cat >"${_tree}/script/x/probe.sh" <<'EOF2'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/enter.sh"
probe_run() { enter_config_check; head -n 1 "${HOME}/.config/worktool/config" >>"${PROBE_LOG}"; }
probe_run
EOF2
    chmod +x "${_tree}/script/x/probe.sh"
    _derive_judges "${_tree}" "${_d}"
    PROBE_LOG="${_log}" run _value_matrix "${_tree}" "${_d}" enter_config_check
    assert_failure
    assert_output --partial 'auto-enter via script/x/probe.sh: empty not refused'
    run cat "${_log}"
    assert_success
    assert_output "$(printf '%s\n' auto-enter auto-enter= 'auto-enter=  ' auto-enter=yes)"
}

# Last: by now both matrix cases have read their judges.
@test "the judges are derived once per file: one derivation per reader" {
    run sort -- "${BATS_FILE_TMPDIR}/derivations"
    assert_success
    assert_output "$(printf '%s\n' "${READERS[@]}" | sort)"
}
