#!/usr/bin/env bats
# test/unit/config_validate_spec.bats - a bare key is that key with an empty
# value, for every reader and validator of the state file (issue #199
# round 10).
#
# lib/config.sh's format: a line without `=` is a bare key with an empty
# value. So every known key gets the same verdict for a bare `<key>` line as
# for `<key>=`. The matrix is every known key x {bare, `key=`, whitespace-only
# value, a valid value}, judged by every script that validates the key:
#   - the decisions and their `.source` (lib/enter.sh): setup and status;
#   - home / home.source (lib/home.sh): status and assemble (--dry-run);
#   - link (lib/link.sh, read by status once a box HOME is recorded).
# A verdict is the exit status plus stderr (the refusal or warning), so
# "identical" means the same outcome AND the same message. Bare, empty and
# whitespace-only are refused (link: warned about and skipped); the valid
# value is accepted.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CONFIG_HOME
    mkdir -p "${HOME}"
    CONFIG="${HOME}/.config/worktool/config"
    # setup resolves distrobox before it writes anything: give it one.
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    printf '#!/bin/sh\nexit 0\n' >"${BATS_TEST_TMPDIR}/bin/distrobox"
    chmod +x "${BATS_TEST_TMPDIR}/bin/distrobox"
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
    export PATH
}

# The known keys: `key|valid value|companion line` (the companion keeps the
# key's pair rule satisfied, so the verdict is about the key itself).
_keys() {
    printf '%s\n' \
        'auto-enter|yes|' 'auto-enter.source|user|' \
        'terminal|none|' 'terminal.source|user|' \
        'tmux|inside|' 'tmux.source|user|' \
        'box|dev|' 'box.source|user|' \
        'home|/srv/box|home.source=user' 'home.source|user|home=/srv/box'
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

# The verdict of script $1 (args $2..) on the state file: `rc=<n>` and its
# stderr, one string.
_verdict() {
    local _err="${BATS_TEST_TMPDIR}/err" _rc=0
    (cd "${REPO_ROOT}" && "$@" >/dev/null 2>"${_err}") || _rc=$?
    printf 'rc=%s %s' "${_rc}" "$(cat "${_err}")"
}

# The scripts that validate key $1, one command per line.
_judges() {
    case "$1" in
        home|home.source)
            printf '%s\n' "${REPO_ROOT}/script/box/status.sh" \
                "${REPO_ROOT}/script/box/assemble.sh --dry-run" ;;
        *)
            printf '%s\n' "${REPO_ROOT}/script/box/status.sh" \
                "${REPO_ROOT}/script/box/setup.sh --dry-run" ;;
    esac
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "bare key = empty value: every validated key, every judge, same verdict; bare, empty and blank refused, valid accepted" {
    local _k _v _c _j _form
    local -a _cmd
    local -A _got
    mkdir -p "$(dirname -- "${CONFIG}")"
    while IFS='|' read -r _k _v _c; do
        while IFS= read -r _j; do
            read -r -a _cmd <<<"${_j}"
            for _form in bare empty ws valid; do
                { _line "${_k}" "${_form}" "${_v}"; [[ -z "${_c}" ]] || printf '%s\n' "${_c}"; } >"${CONFIG}"
                _got[${_form}]="$(_verdict "${_cmd[@]}")"
            done
            [[ "${_got[bare]}" == "${_got[empty]}" ]] \
                || fail "${_k} via ${_j##*/}: bare got '${_got[bare]}', empty got '${_got[empty]}'"
            [[ "${_got[empty]}" == "rc=1 [ERROR] ${CONFIG}: invalid value '' for ${_k}"* ]] \
                || fail "${_k} via ${_j##*/}: empty not refused: ${_got[empty]}"
            [[ "${_got[ws]}" == "rc=1 [ERROR] ${CONFIG}: invalid value '  ' for ${_k}"* ]] \
                || fail "${_k} via ${_j##*/}: whitespace not refused: ${_got[ws]}"
            [[ "${_got[valid]}" == "rc=0 "* ]] \
                || fail "${_k} via ${_j##*/}: valid value refused: ${_got[valid]}"
        done < <(_judges "${_k}")
    done < <(_keys)
}

@test "bare key = empty value: link (bare, empty and blank are warned about and skipped; a path is linked)" {
    local _form _t='~'
    local -A _got _out
    mkdir -p "$(dirname -- "${CONFIG}")"
    for _form in bare empty ws valid; do
        { printf 'home=/srv/box\nhome.source=user\n'; _line link "${_form}" "${_t}/.aws"; } >"${CONFIG}"
        _got[${_form}]="$(_verdict "${REPO_ROOT}/script/box/status.sh")"
        _out[${_form}]="$(cd "${REPO_ROOT}" && "${REPO_ROOT}/script/box/status.sh" 2>/dev/null | grep -c '^link: ')"
    done
    [[ "${_got[bare]}" == "${_got[empty]}" && "${_out[bare]}" == "${_out[empty]}" ]] \
        || fail "link: bare got '${_got[bare]}' (${_out[bare]} lines), empty got '${_got[empty]}' (${_out[empty]} lines)"
    [[ "${_got[empty]}" == "rc=0 [WARN] link: '' in ${CONFIG} is not a path under \$HOME - skipped" ]] \
        || fail "link: empty not warned about: ${_got[empty]}"
    [[ "${_got[ws]}" == "rc=0 [WARN] link: '  ' in ${CONFIG} is not a path under \$HOME - skipped" ]] \
        || fail "link: whitespace not warned about: ${_got[ws]}"
    [[ "${_got[valid]}" == "rc=0 " && "${_out[valid]}" -eq $(( _out[empty] + 1 )) ]] \
        || fail "link: the path was not linked: ${_got[valid]} (${_out[valid]} lines)"
}
