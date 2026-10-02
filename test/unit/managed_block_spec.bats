#!/usr/bin/env bats
# test/unit/managed_block_spec.bats - malformed managed-block markers are
# refused, never rewritten (issue #179, codex round 4 on PR #232)
#
# WHAT THIS PROVES
#   Every file `just box setup` manages holds its worktool block between two
#   exact marker lines. The block helpers of lib/enter.sh used to trust the
#   markers: an orphan BEGIN made enter_block_compose / enter_block_strip
#   skip everything after it to the end of the file, so a rewrite DELETED
#   the user's own lines. The class is "the marker structure is never
#   validated", so there is now one check (enter_block_check) in front of
#   every managed-block write: when the markers are not well-formed - an
#   unpaired BEGIN, an unpaired END, END before BEGIN, a nested BEGIN, more
#   than one block, a marker line with any extra text - setup.sh refuses the
#   whole run BEFORE anything is written (exit 1, one `[ERROR] <file>: ...`
#   line naming the line numbers), and the file keeps every byte.
#
# THE MATRIX
#   marker state (8 malformed + the well-formed control) x operation the run
#   would perform (write a new block, replace a stale one, leave an
#   up-to-date one unchanged, remove it) x managed file (the ghostty config,
#   distrobox.conf). On every malformed cell: exit 1, the error names the
#   file and a line, the file's bytes are unchanged, and nothing else was
#   written (no state file, no other managed file).

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    SETUP="${REPO_ROOT}/script/box/setup.sh"
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CONFIG_HOME
    mkdir -p "${HOME}"
    CONFIG="${HOME}/.config/worktool/config"
    GHOSTTY="${HOME}/.config/ghostty/config"
    DBXCONF="${HOME}/.config/distrobox/distrobox.conf"
    BEGIN="# BEGIN worktool managed block (just box setup; do not edit)"
    END="# END worktool managed block"

    local _dir="${BATS_TEST_TMPDIR}/local/bin"
    mkdir -p "${_dir}"
    printf '#!/bin/sh\nexit 0\n' >"${_dir}/distrobox"
    chmod +x "${_dir}/distrobox"
    PATH="${_dir}:${PATH}"
    export PATH
    DISTROBOX="${_dir}/distrobox"

    # shellcheck source-path=SCRIPTDIR/../../lib
    # shellcheck source=enter.sh
    source "${REPO_ROOT}/lib/enter.sh"
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# The current body setup.sh would write into managed file $1 (ghostty |
# dbxconf) for box dev.
_current_body() {
    case "$1" in
        ghostty) printf "command = %s --distrobox %s --box 'dev'\n" \
            "$(enter_sh_squote "${REPO_ROOT}/script/box/enter.sh")" "$(enter_sh_squote "${DISTROBOX}")" ;;
        dbxconf) enter_distrobox_conf_body dev ;;
    esac
}

# The body the file holds for operation $2 on managed file $1: nothing
# (write a new block), a stale body (replace), the current body (unchanged,
# remove).
_body_for() {
    case "$2" in
        write)            printf '\n' ;;
        replace)          printf 'stale = 1\n' ;;
        unchanged|remove) _current_body "$1" ;;
    esac
}

# The content of a file in marker state $1 around body $2, with user lines
# before and after (the lines a broken rewrite would lose).
_content() {
    local _state="$1" _b="$2"
    case "${_state}" in
        wellformed)  printf 'user-a\n%s\n%s\n%s\nuser-z\n' "${BEGIN}" "${_b}" "${END}" ;;
        orphan-begin) printf 'user-a\n%s\n%s\nuser-z\n' "${BEGIN}" "${_b}" ;;
        orphan-end)  printf 'user-a\n%s\n%s\nuser-z\n' "${_b}" "${END}" ;;
        end-first)   printf 'user-a\n%s\n%s\n%s\nuser-z\n' "${END}" "${_b}" "${BEGIN}" ;;
        nested)      printf 'user-a\n%s\n%s\n%s\n%s\n%s\nuser-z\n' "${BEGIN}" "${BEGIN}" "${_b}" "${END}" "${END}" ;;
        two-blocks)  printf 'user-a\n%s\n%s\n%s\nuser-m\n%s\n%s\n%s\nuser-z\n' "${BEGIN}" "${_b}" "${END}" "${BEGIN}" "${_b}" "${END}" ;;
        begin-extra) printf 'user-a\n%s x\n%s\n%s\nuser-z\n' "${BEGIN}" "${_b}" "${END}" ;;
        end-extra)   printf 'user-a\n%s\n%s\n%s  \nuser-z\n' "${BEGIN}" "${_b}" "${END}" ;;
        indented)    printf 'user-a\n  %s\n%s\n%s\nuser-z\n' "${BEGIN}" "${_b}" "${END}" ;;
    esac
}

# setup.sh arguments that make the run perform operation $1.
_op_args() {
    case "$1" in
        remove) printf '%s\n' --auto-enter no ;;
        *)      printf '%s\n' --terminal ghostty --box dev ;;
    esac
}

# Path of managed file $1.
_path() {
    case "$1" in
        ghostty) printf '%s\n' "${GHOSTTY}" ;;
        dbxconf) printf '%s\n' "${DBXCONF}" ;;
    esac
}

# The other managed file of $1.
_other() {
    case "$1" in
        ghostty) _path dbxconf ;;
        dbxconf) _path ghostty ;;
    esac
}

@test "malformed markers x operation x managed file: refused, exit 1, the file keeps every byte, nothing else is written" {
    local _file _state _op _path _other _before _cell
    local -a _args
    for _file in ghostty dbxconf; do
        for _state in orphan-begin orphan-end end-first nested two-blocks begin-extra end-extra indented; do
            for _op in write replace unchanged remove; do
                _cell="${_file}/${_state}/${_op}"
                rm -rf "${HOME}/.config"
                _path="$(_path "${_file}")"
                _other="$(_other "${_file}")"
                mkdir -p "$(dirname -- "${_path}")"
                _content "${_state}" "$(_body_for "${_file}" "${_op}")" >"${_path}"
                _before="$(sha256sum <"${_path}")"
                mapfile -t _args < <(_op_args "${_op}")
                run "${SETUP}" "${_args[@]}"
                [[ "${status}" -eq 1 ]] || fail "${_cell}: expected exit 1, got ${status}: ${output}"
                [[ "${output}" == *"[ERROR] ${_path}: malformed worktool managed block markers: "*"line"*[0-9]*"; nothing was written"* ]] \
                    || fail "${_cell}: no error naming the file and a line: ${output}"
                [[ "$(sha256sum <"${_path}")" == "${_before}" ]] \
                    || fail "${_cell}: the file changed: $(cat "${_path}")"
                [[ ! -e "${CONFIG}" ]] || fail "${_cell}: the state file was written"
                [[ ! -e "${_other}" ]] || fail "${_cell}: ${_other} was written"
                [[ "${output}" != *"[INFO] wrote:"* && "${output}" != *"[INFO] removed:"* ]] \
                    || fail "${_cell}: a write was logged: ${output}"
            done
        done
    done
}

@test "re-running setup on two managed blocks gives the same refusal and writes nothing" {
    local _file _op _path _before _first_output
    local -a _args
    for _file in ghostty dbxconf; do
        for _op in replace remove; do
            rm -rf "${HOME}/.config"
            _path="$(_path "${_file}")"
            mkdir -p "$(dirname -- "${_path}")"
            _content two-blocks "$(_body_for "${_file}" "${_op}")" >"${_path}"
            _before="$(sha256sum <"${_path}")"
            mapfile -t _args < <(_op_args "${_op}")

            run "${SETUP}" "${_args[@]}"
            assert_failure 1
            assert_line --partial "[ERROR] ${_path}: malformed worktool managed block markers: 2 blocks"
            _first_output="${output}"
            assert_equal "$(sha256sum <"${_path}")" "${_before}"
            assert [ ! -e "${CONFIG}" ]
            assert [ ! -e "$(_other "${_file}")" ]

            run "${SETUP}" "${_args[@]}"
            assert_failure 1
            assert_output "${_first_output}"
            assert_equal "$(sha256sum <"${_path}")" "${_before}"
            assert [ ! -e "${CONFIG}" ]
            assert [ ! -e "$(_other "${_file}")" ]
        done
    done
}

@test "control: well-formed markers x operation x managed file succeed and keep the user lines" {
    local _file _op _path _cell
    local -a _args
    for _file in ghostty dbxconf; do
        for _op in write replace unchanged remove; do
            _cell="${_file}/wellformed/${_op}"
            rm -rf "${HOME}/.config"
            _path="$(_path "${_file}")"
            mkdir -p "$(dirname -- "${_path}")"
            _content wellformed "$(_body_for "${_file}" "${_op}")" >"${_path}"
            mapfile -t _args < <(_op_args "${_op}")
            run "${SETUP}" "${_args[@]}"
            [[ "${status}" -eq 0 ]] || fail "${_cell}: expected exit 0, got ${status}: ${output}"
            grep -qx 'user-a' "${_path}" && grep -qx 'user-z' "${_path}" \
                || fail "${_cell}: user lines lost: $(cat "${_path}")"
        done
    done
}

@test "the error names every problem with its line numbers" {
    mkdir -p "$(dirname -- "${GHOSTTY}")"
    printf 'user-a\n%s\nx\n' "${BEGIN}" >"${GHOSTTY}"
    run "${SETUP}" --terminal ghostty
    assert_failure 1
    assert_line "[ERROR] ${GHOSTTY}: malformed worktool managed block markers: BEGIN at line 2 has no END; nothing was written (fix or remove the markers, then re-run: just box setup)"

    printf '%s\n%s\n' "${END}" "${BEGIN}" >"${GHOSTTY}"
    run "${SETUP}" --terminal ghostty
    assert_line --partial "END at line 1 has no BEGIN; BEGIN at line 2 has no END;"

    printf '%s\n%s\n%s\n%s\n' "${BEGIN}" "${BEGIN}" "${END}" "${END}" >"${GHOSTTY}"
    run "${SETUP}" --terminal ghostty
    assert_line --partial "nested BEGIN at line 2 (BEGIN at line 1 has no END yet)"

    printf '%s\nx\n%s\n%s\ny\n%s\n' "${BEGIN}" "${END}" "${BEGIN}" "${END}" >"${GHOSTTY}"
    run "${SETUP}" --terminal ghostty
    assert_line --partial "2 blocks (BEGIN at lines 1, 4), at most one is allowed"

    printf '%s \n%s\n' "${BEGIN}" "${END}" >"${GHOSTTY}"
    run "${SETUP}" --terminal ghostty
    assert_line --partial "line 1 is a marker with extra text"
}

@test "--dry-run refuses a malformed file the same way (it reports what would happen, and this would fail)" {
    mkdir -p "$(dirname -- "${DBXCONF}")"
    printf 'keep = me\n%s\n' "${BEGIN}" >"${DBXCONF}"
    run "${SETUP}" --dry-run
    assert_failure 1
    assert_line --partial "[ERROR] ${DBXCONF}: malformed worktool managed block markers"
}

@test "enter_block_check: 0 for no file, no markers and one well-formed block; 1 with the problems otherwise" {
    local _f="${BATS_TEST_TMPDIR}/f"
    run enter_block_check "${_f}"
    assert_success
    printf 'a\nb\n' >"${_f}"
    run enter_block_check "${_f}"
    assert_success
    printf 'a\n%s\nb\n%s\nc\n' "${BEGIN}" "${END}" >"${_f}"
    run enter_block_check "${_f}"
    assert_success
    printf 'a\n%s\nb\n' "${BEGIN}" >"${_f}"
    run enter_block_check "${_f}"
    assert_failure 1
    assert_output "BEGIN at line 2 has no END"
}

@test "status reports a malformed block as MALFORMED instead of present" {
    mkdir -p "$(dirname -- "${GHOSTTY}")"
    printf 'user-a\n%s\nx\n' "${BEGIN}" >"${GHOSTTY}"
    run "${REPO_ROOT}/script/box/status.sh"
    assert_success
    assert_line "ghostty: ${GHOSTTY} (managed block: MALFORMED - BEGIN at line 2 has no END; fix or remove the markers, then re-run: just box setup)"
}
