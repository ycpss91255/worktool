#!/usr/bin/env bash
# Replay the real product and corrupt only the behavior a negative names.
set -euo pipefail

_out="$(mktemp)"
trap 'rm -f -- "${_out}" "${_out}.stripped"' EXIT
_rc=0
"${VERIFY_REAL_JUST}" "$@" >"${_out}" 2>&1 || _rc=$?
if [[ "${1:-}:${2:-}" == box:setup && "${VERIFY_CORRUPTION}" == malformed-write ]]; then
    if [[ -f "${HOME}/.config/ghostty/config" ]] && \
        [[ "$(cat "${HOME}/.config/ghostty/config")" == *'user content'* ]]; then
        printf 'unexpected\n' >"${HOME}/unexpected"
    fi
fi
_cfg="${XDG_CONFIG_HOME:-${HOME}/.config}/ghostty/config"
if [[ "${1:-}:${2:-}" == box:setup && -f "${_cfg}" ]]; then
    case "${VERIFY_CORRUPTION}" in
        trailing-blank) printf '\n' >>"${HOME}/.tmux.conf" ;;
        missing-newline)
            _user="$(cat "${HOME}/.tmux.conf")"
            printf '%s' "${_user}" >"${HOME}/.tmux.conf"
            ;;
        bare-name) sed -i 's|^command = .*|command = distrobox enter dev|' "${_cfg}" ;;
        no-block)
            # shellcheck source=lib/enter.sh
            source "${VERIFY_PRODUCT_LIB}"
            enter_block_strip "${_cfg}" >"${_out}.stripped"
            cp -- "${_out}.stripped" "${_cfg}"
            ;;
    esac
fi
if [[ "${1:-}:${2:-}" == box:setup && " $* " == *' --auto-enter no '* && "${VERIFY_CORRUPTION}" == tmux-message ]]; then
    printf '%s\n' "${VERIFY_CRITERION}" >>"${_out}"
fi
while IFS= read -r _line; do
    if [[ "${VERIFY_CORRUPTION}" == bare-name && "${_line}" == *'(managed block: command = '* ]]; then
        _cmd="${_line#*'(managed block: '}"
        _cmd="${_cmd%')'}"
        _line="${_line//"${_cmd}"/command = distrobox enter dev}"
    fi
    if [[ -n "${VERIFY_CRITERION:-}" && "${_line}" == *"${VERIFY_CRITERION}"* ]]; then
        [[ "${VERIFY_CORRUPTION}" != omit-line ]] || continue
        if [[ "${VERIFY_CORRUPTION}" == duplicate-line ]]; then printf '%s\n' "${_line}"; fi
    fi
    printf '%s\n' "${_line}"
done <"${_out}"
exit "${_rc}"
