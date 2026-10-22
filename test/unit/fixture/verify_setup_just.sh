#!/usr/bin/env bash
# Replay the real product and corrupt only the behavior a negative names.
set -euo pipefail

_out="$(mktemp)"
trap 'rm -f -- "${_out}" "${_out}.stripped"' EXIT
_rc=0
"${VERIFY_REAL_JUST}" "$@" >"${_out}" 2>&1 || _rc=$?
_cfg="${XDG_CONFIG_HOME:-${HOME}/.config}/ghostty/config"
if [[ "${1:-}:${2:-}" == box:setup && -f "${_cfg}" ]]; then
    case "${VERIFY_CORRUPTION}" in
        bare-name) sed -i 's|^command = .*|command = distrobox enter dev|' "${_cfg}" ;;
        no-block)
            # shellcheck source=lib/enter.sh
            source "${VERIFY_PRODUCT_LIB}"
            enter_block_strip "${_cfg}" >"${_out}.stripped"
            cp -- "${_out}.stripped" "${_cfg}"
            ;;
    esac
fi
while IFS= read -r _line; do
    if [[ "${VERIFY_CORRUPTION}" == bare-name && "${_line}" == *'(managed block: command = '* ]]; then
        _cmd="${_line#*'(managed block: '}"
        _cmd="${_cmd%')'}"
        _line="${_line//"${_cmd}"/command = distrobox enter dev}"
    fi
    printf '%s\n' "${_line}"
done <"${_out}"
exit "${_rc}"
