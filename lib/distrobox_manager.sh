#!/usr/bin/env bash
# lib/distrobox_manager.sh - resolve the engine used by distrobox without
# depending on worktool's state-file reader. Sourced library; no shell options.
# distrobox_manager <config-directory> prints the engine; returns 1 if it is
# unavailable, or 2 if a container_manager setting cannot be parsed.

# The container manager distrobox would use, the way distrobox-create
# 1.8.2.5 picks it: DBX_CONTAINER_MANAGER when set and non-empty, else the
# last `container_manager=` of its config files (read, never sourced),
# else autodetect in its order (podman, podman-launcher, docker, lilipod).
# Prints the name; returns 1 (still printing the name, or `autodetect`)
# when that manager is not on PATH; 2 (printing the config file) when a
# `container_manager=` line there cannot be read as a manager name.
distrobox_manager() {
    local _m="${DBX_CONTAINER_MANAGER:-}"
    if [[ -z "${_m}" ]] && ! _m="$(_dbx_manager_conf "$1")"; then
        printf '%s\n' "${_m}"
        return 2
    fi
    [[ -n "${_m}" ]] || _m=autodetect
    if [[ "${_m}" == autodetect ]]; then
        local _c
        for _c in podman podman-launcher docker lilipod; do
            if command -v -- "${_c}" >/dev/null 2>&1; then
                printf '%s\n' "${_c}"
                return 0
            fi
        done
        printf '%s\n' "${_m}"
        return 1
    fi
    printf '%s\n' "${_m}"
    command -v -- "${_m}" >/dev/null 2>&1
}

# The config files distrobox-create reads, lowest priority first.
_dbx_manager_conf_files() {
    local _dbx
    if _dbx="$(command -v distrobox 2>/dev/null)" && [[ "${_dbx}" == /* ]]; then
        printf '%s\n' "$(dirname -- "$(realpath -- "${_dbx}")")/../share/distrobox/distrobox.conf"
    fi
    printf '%s\n' /usr/share/distrobox/distrobox.conf \
        /usr/share/defaults/distrobox/distrobox.conf \
        /usr/etc/distrobox/distrobox.conf \
        /usr/local/share/distrobox/distrobox.conf \
        /etc/distrobox/distrobox.conf \
        "${1}/distrobox/distrobox.conf" \
        "${HOME}/.distroboxrc"
}

# The last `container_manager=<value>` assignment across distrobox's
# config files, read the way the shell reads a plain name: optional
# matching quotes, optional trailing `# comment`. Nothing when none sets
# it. A line it cannot read that way (empty, a substitution, ...) returns
# 1 printing that file: distrobox sources it, so skipping it could ask a
# different manager than the one distrobox uses.
_dbx_manager_conf() {
    local _f _line _m=""
    local _q="'" _re
    # No back-reference: POSIX ERE (musl) has none, so spell the 3 quotings.
    _re='^[[:space:]]*container_manager=([A-Za-z0-9_-]+|"[A-Za-z0-9_-]+"|'
    _re+="${_q}[A-Za-z0-9_-]+${_q}"')([[:space:]]+#.*)?[[:space:]]*$'
    while IFS= read -r _f; do
        [[ -f "${_f}" && -r "${_f}" ]] || continue
        while IFS= read -r _line || [[ -n "${_line}" ]]; do
            [[ "${_line}" =~ ^[[:space:]]*container_manager= ]] || continue
            if [[ ! "${_line}" =~ ${_re} ]]; then
                printf '%s\n' "${_f}"
                return 1
            fi
            _m="${BASH_REMATCH[1]//[\"\']/}"
        done <"${_f}"
    done < <(_dbx_manager_conf_files "$1")
    printf '%s\n' "${_m}"
}

