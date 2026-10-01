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
#     the modules in its source graph (test/helper/graph.bash graph_judges);
#   - a verdict is the exit status, stdout and stderr; bare and `key=` must
#     give byte-identical stdout and stderr files (cmp) and the same status;
#     bare, empty and blank are refused (link: warned about and skipped), a
#     valid value is accepted (link: linked).

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/graph"

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
        'tmux|enter_config_check|inside|' 'tmux.source|enter_config_check|user|' \
        'box|enter_config_check|dev|' 'box.source|enter_config_check|user|' \
        "home|home_config_check|${BATS_TEST_TMPDIR}/box|home.source=user" \
        "home.source|home_config_check|user|home=${BATS_TEST_TMPDIR}/box"
}

# The judges of reader function $1: every script that calls it, derived
# from the source graph. An empty set fails the case instead of passing it
# vacuously.
_judges() {
    local _j
    _j="$(graph_judges "${REPO_ROOT}" "$1")" || fail "cannot derive the judges of $1"
    [[ -n "${_j}" ]] || fail "no script calls $1"
    printf '%s\n' "${_j}"
}

# The command a judge script runs as: status and assemble as a user would
# (assemble for real, against the fake manager); setup with --dry-run.
_command() {
    case "$1" in
        script/box/setup.sh) printf '%s\n' "${REPO_ROOT}/$1 --dry-run" ;;
        *) printf '%s\n' "${REPO_ROOT}/$1" ;;
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
    (cd "${REPO_ROOT}" && "${_cmd[@]}" >"${_p}.out" 2>"${_p}.err") || _rc=$?
    printf '%s\n' "${_rc}" >"${_p}.rc"
}

# Fail unless forms bare and empty (prefix $1.) gave byte-identical files.
_assert_same() {
    local _x
    for _x in rc out err; do
        cmp -s -- "$1.bare.${_x}" "$1.empty.${_x}" \
            || fail "$2: bare and \`key=\` differ in ${_x}: $(diff "$1.bare.${_x}" "$1.empty.${_x}")"
    done
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "bare key = empty value: every judged key, every judge, identical bytes; bare, empty and blank refused, valid accepted" {
    local _k _r _v _c _s _form _p
    # Derived here, in this shell, so an empty or failed derivation fails
    # the case rather than running no judge.
    for _r in enter_config_check home_config_check; do _judges "${_r}" >/dev/null; done
    mkdir -p "$(dirname -- "${CONFIG}")"
    while IFS='|' read -r _k _r _v _c; do
        while IFS= read -r _s; do
            _p="${BATS_TEST_TMPDIR}/v.${_k}.${_s##*/}"
            for _form in bare empty ws valid; do
                rm -rf "${BOX}"
                { _line "${_k}" "${_form}" "${_v}"; [[ -z "${_c}" ]] || printf '%s\n' "${_c}"; } >"${CONFIG}"
                _judge "${_p}.${_form}" "$(_command "${_s}")"
            done
            _assert_same "${_p}" "${_k} via ${_s}"
            [[ "$(cat "${_p}.empty.rc")" == 1 ]] \
                && grep -qF "[ERROR] ${CONFIG}: invalid value '' for ${_k}" "${_p}.empty.err" \
                || fail "${_k} via ${_s}: empty not refused: $(cat "${_p}.empty.err")"
            [[ "$(cat "${_p}.ws.rc")" == 1 ]] \
                && grep -qF "[ERROR] ${CONFIG}: invalid value '  ' for ${_k}" "${_p}.ws.err" \
                || fail "${_k} via ${_s}: whitespace not refused: $(cat "${_p}.ws.err")"
            [[ "$(cat "${_p}.valid.rc")" == 0 ]] \
                || fail "${_k} via ${_s}: valid value refused: $(cat "${_p}.valid.err")"
        done < <(_judges "${_r}")
    done < <(_keys)
}

@test "bare key = empty value: link, every judge (bare, empty and blank warned about and skipped; a path linked)" {
    local _s _form _p _t='~'
    # assemble reaches link_entries only through link_apply: the derivation
    # must follow that chain.
    _judges link_entries | grep -qx script/box/assemble.sh \
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
    done < <(_judges link_entries)
}
