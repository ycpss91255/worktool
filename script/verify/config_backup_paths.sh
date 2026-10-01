# Acceptance backup paths for the current setup contract (PR #232 / #351).
# Sourced after lib/config_backup.sh; the manifest and byte-preserving backup
# machinery remain shared, while the acceptance layer owns this file set.
CFGBK_NAMES=(ghostty ghostty-modern worktool distrobox-conf)
CFGBK_USER_NAMES=(ghostty ghostty-modern distrobox-conf)

cfgbk_file_of() {
    case "$1" in
        ghostty) printf '%s/ghostty/config\n' "${CFGBK_C}" ;;
        ghostty-modern) printf '%s/ghostty/config.ghostty\n' "${CFGBK_C}" ;;
        worktool) printf '%s/worktool/config\n' "${CFGBK_C}" ;;
        distrobox-conf) printf '%s/distrobox/distrobox.conf\n' "${CFGBK_C}" ;;
        *) guard_fail "unknown config name '$1'"; return 1 ;;
    esac
}

cfgbk_dir_of() {
    case "$1" in
        ghostty | ghostty-modern) printf '%s/ghostty\n' "${CFGBK_C}" ;;
        worktool) printf '%s/worktool\n' "${CFGBK_C}" ;;
        distrobox-conf) printf '%s/distrobox\n' "${CFGBK_C}" ;;
        *) guard_fail "unknown config name '$1'"; return 1 ;;
    esac
}

cfgbk_label_of() {
    case "$1" in
        ghostty-modern) printf 'config.ghostty\n' ;;
        distrobox-conf) printf 'distrobox.conf\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# Both Ghostty files share a directory. Remove newly created files before
# restoring either absent directory, so the sibling cannot obstruct rmdir.
cfgbk_restore_all() {
    local _n _s _p _rc=0
    for _n in ghostty ghostty-modern; do
        _s="$(guard_field "${CFGBK_B}" "${_n}")" || return 1
        if [[ "${_s}" == absent-dir ]]; then
            _p="$(cfgbk_file_of "${_n}")" || return 1
            rm -f -- "${_p}" || return 1
        fi
    done
    for _n in "${CFGBK_NAMES[@]}"; do
        cfgbk_restore_one "${_n}" || _rc=1
    done
    return "${_rc}"
}
