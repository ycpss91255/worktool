#!/usr/bin/env bash
# test/unit/fixture/realbox_tool.sh - one fake for the four tools that
# script/verify/realbox.sh drives: distrobox, just, gh and jq.
#
# test/unit/verify_realbox_spec.bats installs this file under all four names
# in a stub directory placed first on PATH; it dispatches on $0's basename.
#
# Everything here uses bash BUILTINS only (no basename, grep, cp, ...): the
# same spec also shims real coreutils to fail, and a fake that depended on
# them would break for reasons that have nothing to do with the case at hand.
#
# State lives under $FAKE_STATE_DIR:
#   boxes              one box name per line - what `distrobox list` reports
#   calls.log          `<tool> <argv>` for every call
#   last-comment-body  the body `gh issue comment` was handed
#
# Every fake can be told to print PLAUSIBLE output and STILL exit non-zero -
# that combination is the exact bug the spec exists to rule out.
#
# Env knobs:
#   distrobox  FAKE_DBX_LIST_RC / FAKE_DBX_LIST_OUT
#              FAKE_DBX_CREATE_RC / FAKE_DBX_CREATE_OUT / FAKE_DBX_CREATE_REGISTERS
#              FAKE_DBX_RM_RC / FAKE_DBX_RM_REMOVES
#   just       FAKE_JUST_<VERB>_RC / FAKE_JUST_<VERB>_OUT for assemble, bench,
#              setup, status; FAKE_JUST_ASSEMBLE_REGISTERS;
#              FAKE_JUST_BOX_SCRIPT_DIR runs the REAL script/box/<verb>.sh of
#              that directory for `box setup` / `box status` (the degraded-copy
#              family: a copy of the checkout is degraded and driven for real)
#   gh         FAKE_GH_COMMENT_RC / FAKE_GH_COMMENT_OUT / FAKE_GH_COMMENT_ID
#              FAKE_GH_API_RC / FAKE_GH_API_OUT
#   jq         FAKE_JQ_RC / FAKE_JQ_OUT
#
# Exit-code-contract fixture: `set -uo pipefail`, no `-e` (doc/adr/0007).

set -uo pipefail

_DIR="${FAKE_STATE_DIR:?FAKE_STATE_DIR must be set}"
_ME="${0##*/}"
_BOX="${FAKE_BOX_NAME:-dev}"

_DEFAULT_BENCH='enter: min=136.1 median=171.1 max=197.0 ms
shell: min=143.8 median=176.9 max=215.5 ms
inbox: min=14.9 median=17.5 max=25.4 ms
[INFO] shell median 176.9 ms within --max-ms 300'

printf '%s %s\n' "${_ME}" "$*" >>"${_DIR}/calls.log"

# --- box bookkeeping (pure bash) ---------------------------------------------
_box_add() {
    printf '%s\n' "$1" >>"${_DIR}/boxes"
}

_box_drop() {
    local _line _kept=()
    while IFS= read -r _line; do
        [[ -z "${_line}" || "${_line}" == "$1" ]] && continue
        _kept+=("${_line}")
    done <"${_DIR}/boxes"
    : >"${_DIR}/boxes"
    local _k
    for _k in ${_kept[@]+"${_kept[@]}"}; do
        printf '%s\n' "${_k}" >>"${_DIR}/boxes"
    done
}

# --- distrobox ---------------------------------------------------------------
_fake_distrobox_list() {
    local _rc="${FAKE_DBX_LIST_RC:-0}" _n=0 _line
    # Count the list calls so a test can break the Nth one only: a
    # `distrobox list` that fails LATE (after the box was created) is how the
    # spec reaches the "still there" check of 5.3.
    printf 'x\n' >>"${_DIR}/list-calls"
    while IFS= read -r _line; do
        _n=$((_n + 1))
    done <"${_DIR}/list-calls"
    if [[ -n "${FAKE_DBX_LIST_FAIL_FROM-}" && "${_n}" -ge "${FAKE_DBX_LIST_FAIL_FROM}" ]]; then
        _rc=1
    fi
    # The table is printed either way: plausible output plus a non-zero exit
    # is exactly the shape an unguarded check would read as "no such box".
    if [[ -n "${FAKE_DBX_LIST_OUT+x}" ]]; then
        printf '%s\n' "${FAKE_DBX_LIST_OUT}"
    else
        printf 'ID | NAME | STATUS | IMAGE\n'
        while IFS= read -r _line; do
            [[ -n "${_line}" ]] || continue
            printf '0000 | %s | Up | ubuntu:24.04\n' "${_line}"
        done <"${_DIR}/boxes"
    fi
    return "${_rc}"
}

_fake_distrobox_create() {
    local _name="" _prev=""
    local _a
    for _a in "$@"; do
        [[ "${_prev}" == "--name" ]] && _name="${_a}"
        _prev="${_a}"
    done
    if [[ "${FAKE_DBX_CREATE_RC:-0}" -ne 0 ]]; then
        [[ -n "${FAKE_DBX_CREATE_OUT-}" ]] && printf '%s\n' "${FAKE_DBX_CREATE_OUT}"
        return "${FAKE_DBX_CREATE_RC}"
    fi
    [[ "${FAKE_DBX_CREATE_REGISTERS:-1}" -eq 1 ]] && _box_add "${_name:-${_BOX}}"
    return 0
}

_fake_distrobox_rm() {
    local _name="" _a
    for _a in "$@"; do
        case "${_a}" in
            -f | --force | --yes) ;;
            *) _name="${_a}" ;;
        esac
    done
    [[ "${FAKE_DBX_RM_REMOVES:-1}" -eq 1 ]] && _box_drop "${_name:-${_BOX}}"
    return "${FAKE_DBX_RM_RC:-0}"
}

_fake_distrobox() {
    local _verb="${1:-}"
    shift || true
    case "${_verb}" in
        list) _fake_distrobox_list ;;
        create) _fake_distrobox_create "$@" ;;
        rm) _fake_distrobox_rm "$@" ;;
        --version)
            printf 'distrobox: fake\n'
            return 0
            ;;
        *) return 0 ;;
    esac
}

# --- just --------------------------------------------------------------------
# argv always starts `box <verb>` (script/verify/realbox.sh only ever calls
# the box namespace).
_fake_just() {
    local _verb="${2:-}" _rc _out
    case "${_verb}" in
        assemble)
            _rc="${FAKE_JUST_ASSEMBLE_RC:-0}"
            _out="${FAKE_JUST_ASSEMBLE_OUT-distrobox assemble create --file box/dev.ini}"
            [[ -n "${_out}" ]] && printf '%s\n' "${_out}"
            [[ "${_rc}" -eq 0 && "${FAKE_JUST_ASSEMBLE_REGISTERS:-1}" -eq 1 ]] && _box_add "${_BOX}"
            return "${_rc}"
            ;;
        bench)
            _out="${FAKE_JUST_BENCH_OUT-${_DEFAULT_BENCH}}"
            [[ -n "${_out}" ]] && printf '%s\n' "${_out}"
            return "${FAKE_JUST_BENCH_RC:-0}"
            ;;
        setup | status)
            # FAKE_JUST_BOX_SCRIPT_DIR runs the REAL product instead of
            # answering canned text, so a DEGRADED COPY of the checkout can
            # be driven through `just box <verb>`: that is the only way to
            # ask whether 5.2 catches a product that writes the files it
            # says it writes and destroys the user's content doing it.
            if [[ -n "${FAKE_JUST_BOX_SCRIPT_DIR-}" ]]; then
                "${FAKE_JUST_BOX_SCRIPT_DIR}/${_verb}.sh" "${@:3}"
                return $?
            fi
            if [[ "${_verb}" == setup ]]; then
                _out="${FAKE_JUST_SETUP_OUT-[INFO] auto-enter: yes (default)}"
                [[ -n "${_out}" ]] && printf '%s\n' "${_out}"
                return "${FAKE_JUST_SETUP_RC:-0}"
            fi
            _out="${FAKE_JUST_STATUS_OUT-auto-enter: yes (default)}"
            [[ -n "${_out}" ]] && printf '%s\n' "${_out}"
            return "${FAKE_JUST_STATUS_RC:-0}"
            ;;
        *) return 0 ;;
    esac
}

# --- gh ----------------------------------------------------------------------
_fake_gh_comment() {
    local _bf="" _prev="" _a _line
    for _a in "$@"; do
        [[ "${_prev}" == "--body-file" ]] && _bf="${_a}"
        _prev="${_a}"
    done
    if [[ -n "${_bf}" && -r "${_bf}" ]]; then
        : >"${_DIR}/last-comment-body"
        while IFS= read -r _line; do
            printf '%s\n' "${_line}" >>"${_DIR}/last-comment-body"
        done <"${_bf}"
    fi
    printf '%s\n' \
        "${FAKE_GH_COMMENT_OUT-https://github.com/ycpss91255/worktool/issues/22#issuecomment-${FAKE_GH_COMMENT_ID:-9001}}"
    return "${FAKE_GH_COMMENT_RC:-0}"
}

_fake_gh() {
    case "${1:-}" in
        issue)
            _fake_gh_comment "$@"
            ;;
        api)
            printf '%s\n' \
                "${FAKE_GH_API_OUT-{\"issue_url\":\"https://api.github.com/repos/ycpss91255/worktool/issues/22\",\"body\":\"fake\"\}}"
            return "${FAKE_GH_API_RC:-0}"
            ;;
        *) return 0 ;;
    esac
}

# --- jq ----------------------------------------------------------------------
# The verdict itself is injected: what this spec proves is that realbox.sh
# separates jq's ANSWER from jq's exit STATUS, not that the filter is right.
_fake_jq() {
    printf '%s\n' "${FAKE_JQ_OUT-1}"
    return "${FAKE_JQ_RC:-0}"
}

# --- dispatch ----------------------------------------------------------------
case "${_ME}" in
    distrobox) _fake_distrobox "$@" ;;
    just) _fake_just "$@" ;;
    gh) _fake_gh "$@" ;;
    jq) _fake_jq "$@" ;;
    *)
        printf 'realbox_tool.sh: installed under an unknown name: %s\n' "${_ME}" >&2
        exit 127
        ;;
esac
