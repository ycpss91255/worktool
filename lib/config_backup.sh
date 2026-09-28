#!/usr/bin/env bash
# lib/config_backup.sh - back up, re-validate and restore the user config
# files that `just box setup` rewrites, behind a manifest that is published
# atomically.
#
# Extracted from acceptance item 5.2 (doc/acceptance.md), whose three pasted
# blocks this backs. The shape matters:
#
#   step 1  copies each config and writes $B/manifest.partial, then renames it
#           to $B/manifest. Until that rename nothing has been applied, so a
#           step 1 that dies can delete its own half-written backup.
#   step 2  trusts ONLY the published manifest on disk - never a variable left
#           over from step 1 - and re-hashes everything before applying.
#   step 3  restores from the manifest and can run alone in a fresh shell,
#           which makes it the recovery path after an interrupt.
#
# `cp -a` is `-dR --preserve=all`: mode and mtime survive and symlinks are NOT
# dereferenced, so a link is backed up as a link AND the file behind it is
# backed up too (setup replaces the link today, but a future one could write
# through it).
#
# Every comparison here reads each side into a variable and checks its status
# first. Compared raw, two failed reads both yield "" and "match" - which is
# how an unreadable backup would certify itself as intact.
#
# Public API (all return 0 on success, 1 with a `[FAIL]` reason on stderr):
#   cfgbk_paths                 set CFGBK_C / CFGBK_B from the environment
#   cfgbk_dir_create            create $CFGBK_B, refusing one we did not make
#   cfgbk_abort                 delete a half-written backup, print ok=0
#   cfgbk_backup_body           write and publish the manifest, print ok=1
#   cfgbk_states_ok             exactly one valid state line per name
#   cfgbk_revalidate            re-check disk against the published manifest
#   cfgbk_restore_one <name>    put one config back the way it was
#   cfgbk_report_blocks         print `blocks=N`, fail if N is not 0
#   cfgbk_report_leftover_dirs  print `leftover-dirs=N`, fail if N is not 0
#
# Requires lib/guard.sh to be sourced first.
#
# This is a library: it defines functions and must be sourced, not executed.

# The config names this library knows about (the two `just box setup` writes).
CFGBK_NAMES=(ghostty worktool)
CFGBK_C=""
CFGBK_B=""

# The backup path carries the uid so a shared host cannot collide. `id -u` is
# status-checked: interpolated raw, a broken `id` would silently hand every
# user on the machine the SAME backup directory.
cfgbk_paths() {
    local _uid
    CFGBK_C="${XDG_CONFIG_HOME:-${HOME}/.config}"
    _uid="$(id -u)" || { guard_fail "id -u failed"; return 1; }
    [[ "${_uid}" =~ ^[0-9]+$ ]] \
        || { guard_fail "id -u printed '${_uid}', which is not a uid"; return 1; }
    CFGBK_B="${TMPDIR:-/tmp}/worktool-m3-52-backup.${_uid}"
    return 0
}

# Refuse a backup a previous run left behind, and never write into a directory
# (or through a symlink) we did not create ourselves.
cfgbk_dir_create() {
    if ! mkdir -m 700 -- "${CFGBK_B}" 2>/dev/null; then
        printf 'backup=%s ok=0\n' "${CFGBK_B}"
        guard_fail "backup dir already exists: ${CFGBK_B} -- run 5.2.3 to restore from it, confirm clean, then re-run 5.2.1"
        return 1
    fi
    if ! { [[ -d "${CFGBK_B}" ]] && [[ ! -L "${CFGBK_B}" ]] && [[ -O "${CFGBK_B}" ]]; }; then
        guard_fail "${CFGBK_B} is not a directory we own"
        return 1
    fi
    return 0
}

cfgbk_abort() {
    rm -rf -- "${CFGBK_B}"
    printf 'backup=%s ok=0\n' "${CFGBK_B}"
    return 1
}

cfgbk_states_ok() {
    local _file="$1" _n _c
    for _n in "${CFGBK_NAMES[@]}"; do
        _c="$(guard_count_lines "${_file}" "^${_n}=(regular|symlink|absent-file|absent-dir)\$")" \
            || { guard_fail "${_n}: cannot count the manifest state lines"; return 1; }
        [[ "${_c}" -eq 1 ]] \
            || { guard_fail "${_n}: manifest does not have exactly one state line"; return 1; }
    done
    return 0
}

# --- step 1: back up ---------------------------------------------------------

# Append one manifest line per argument. Command substitution would strip the
# trailing newline, so the lines are passed as separate arguments instead.
_cfgbk_manifest_add() {
    local _l
    for _l in "$@"; do
        printf '%s\n' "${_l}" >>"${CFGBK_B}/manifest.partial" \
            || { guard_fail "writing the manifest failed"; return 1; }
    done
}

_cfgbk_backup_regular() {
    local _n="$1" _p="$2" _sha
    cp -a -- "${_p}" "${CFGBK_B}/${_n}.config" \
        || { guard_fail "${_n}: backup copy failed"; return 1; }
    _sha="$(guard_sha256 "${CFGBK_B}/${_n}.config")" \
        || { guard_fail "${_n}: hashing the backup failed"; return 1; }
    _cfgbk_manifest_add "${_n}=regular" "${_n}.sha=${_sha}"
}

_cfgbk_backup_link_target() {
    local _n="$1" _p="$2" _tp _tsha
    if [[ ! -e "${_p}" ]]; then
        # A dangling link: there is nothing behind it to preserve.
        _cfgbk_manifest_add "${_n}.tpath="
        return
    fi
    _tp="$(readlink -f -- "${_p}")" \
        || { guard_fail "${_n}: cannot resolve the link target"; return 1; }
    [[ -n "${_tp}" ]] \
        || { guard_fail "${_n}: readlink -f printed nothing for ${_p}"; return 1; }
    [[ -f "${_tp}" ]] \
        || { guard_fail "${_n}: link target ${_tp} is not a regular file -- handle it by hand"; return 1; }
    cp -a -- "${_tp}" "${CFGBK_B}/${_n}.target" \
        || { guard_fail "${_n}: backing up the link target failed"; return 1; }
    _tsha="$(guard_sha256 "${CFGBK_B}/${_n}.target")" \
        || { guard_fail "${_n}: hashing the link target backup failed"; return 1; }
    _cfgbk_manifest_add "${_n}.tpath=${_tp}" "${_n}.tsha=${_tsha}"
}

_cfgbk_backup_symlink() {
    local _n="$1" _p="$2" _blink _plink
    cp -a -- "${_p}" "${CFGBK_B}/${_n}.config" \
        || { guard_fail "${_n}: backup copy failed"; return 1; }
    [[ "$(guard_path_type "${CFGBK_B}/${_n}.config")" == symlink ]] \
        || { guard_fail "${_n}: the backup is not a symlink -- refusing to continue"; return 1; }
    _blink="$(readlink -- "${CFGBK_B}/${_n}.config")" \
        || { guard_fail "${_n}: cannot read the backup link"; return 1; }
    _plink="$(readlink -- "${_p}")" \
        || { guard_fail "${_n}: cannot read the live link"; return 1; }
    [[ "${_blink}" == "${_plink}" ]] \
        || { guard_fail "${_n}: backup link target differs from the original"; return 1; }
    _cfgbk_manifest_add "${_n}=symlink" "${_n}.link=${_plink}" || return 1
    _cfgbk_backup_link_target "${_n}" "${_p}"
}

_cfgbk_backup_one() {
    local _n="$1" _p="${CFGBK_C}/$1/config"
    case "$(guard_path_type "${_p}")" in
        regular) _cfgbk_backup_regular "${_n}" "${_p}" ;;
        symlink) _cfgbk_backup_symlink "${_n}" "${_p}" ;;
        absent)
            if [[ -d "${CFGBK_C}/${_n}" ]]; then
                _cfgbk_manifest_add "${_n}=absent-file"
            else
                _cfgbk_manifest_add "${_n}=absent-dir"
            fi
            ;;
        *)
            guard_fail "${_n}: ${_p} is neither a regular file nor a symlink -- handle it by hand"
            return 1
            ;;
    esac
}

cfgbk_backup_body() {
    local _n
    : >"${CFGBK_B}/manifest.partial" || { guard_fail "cannot start the manifest"; return 1; }
    for _n in "${CFGBK_NAMES[@]}"; do
        _cfgbk_backup_one "${_n}" || return 1
    done
    cfgbk_states_ok "${CFGBK_B}/manifest.partial" || return 1
    # Publishing is the atomic commit point: step 2 trusts this file and
    # nothing else, least of all a variable left over from this shell.
    mv -- "${CFGBK_B}/manifest.partial" "${CFGBK_B}/manifest" \
        || { guard_fail "publishing the manifest failed"; return 1; }
    cat -- "${CFGBK_B}/manifest" || { guard_fail "cannot read the published manifest"; return 1; }
    printf 'backup=%s ok=1\n' "${CFGBK_B}"
}

# --- step 2: re-validate the published backup --------------------------------

_cfgbk_revalidate_regular() {
    local _n="$1" _p="$2" _bp="$3" _bsha _psha _msha
    [[ "$(guard_path_type "${_bp}")" == regular ]] \
        || { guard_fail "${_n}: the backup is not a regular file"; return 1; }
    [[ "$(guard_path_type "${_p}")" == regular ]] \
        || { guard_fail "${_n}: live config is no longer a regular file"; return 1; }
    _bsha="$(guard_sha256 "${_bp}")" \
        || { guard_fail "${_n}: hashing the backup failed"; return 1; }
    _msha="$(guard_field "${CFGBK_B}" "${_n}.sha")" \
        || { guard_fail "${_n}: the manifest records no checksum"; return 1; }
    [[ "${_bsha}" == "${_msha}" ]] \
        || { guard_fail "${_n}: backup does not match its manifest checksum"; return 1; }
    _psha="$(guard_sha256 "${_p}")" \
        || { guard_fail "${_n}: hashing the live config failed"; return 1; }
    [[ "${_bsha}" == "${_psha}" ]] \
        || { guard_fail "${_n}: live config changed since step 1 -- run 5.2.3, then 5.2.1 again"; return 1; }
}

_cfgbk_revalidate_target() {
    local _n="$1" _tp="$2" _msha _tsha
    [[ "$(guard_path_type "${CFGBK_B}/${_n}.target")" == regular ]] \
        || { guard_fail "${_n}: the link target was not backed up"; return 1; }
    _msha="$(guard_field "${CFGBK_B}" "${_n}.tsha")" \
        || { guard_fail "${_n}: the manifest records no link-target checksum"; return 1; }
    _tsha="$(guard_sha256 "${CFGBK_B}/${_n}.target")" \
        || { guard_fail "${_n}: hashing the link-target backup failed"; return 1; }
    [[ "${_tsha}" == "${_msha}" ]] \
        || { guard_fail "${_n}: target backup does not match its manifest checksum"; return 1; }
    [[ -f "${_tp}" ]] \
        || { guard_fail "${_n}: link target ${_tp} disappeared since step 1"; return 1; }
    _tsha="$(guard_sha256 "${_tp}")" \
        || { guard_fail "${_n}: hashing the live link target failed"; return 1; }
    [[ "${_tsha}" == "${_msha}" ]] \
        || { guard_fail "${_n}: link target ${_tp} changed since step 1"; return 1; }
}

_cfgbk_revalidate_symlink() {
    local _n="$1" _p="$2" _bp="$3" _blink _plink _mlink _tp
    [[ "$(guard_path_type "${_bp}")" == symlink ]] \
        || { guard_fail "${_n}: the backup did not preserve the symlink"; return 1; }
    [[ "$(guard_path_type "${_p}")" == symlink ]] \
        || { guard_fail "${_n}: live config is no longer a symlink"; return 1; }
    _blink="$(readlink -- "${_bp}")" \
        || { guard_fail "${_n}: cannot read the backup link"; return 1; }
    _plink="$(readlink -- "${_p}")" \
        || { guard_fail "${_n}: cannot read the live link"; return 1; }
    _mlink="$(guard_field "${CFGBK_B}" "${_n}.link")" \
        || { guard_fail "${_n}: the manifest records no link target"; return 1; }
    [[ "${_blink}" == "${_mlink}" ]] \
        || { guard_fail "${_n}: backup link target differs from the manifest"; return 1; }
    [[ "${_plink}" == "${_mlink}" ]] \
        || { guard_fail "${_n}: live link target changed since step 1"; return 1; }
    _tp="$(guard_field "${CFGBK_B}" "${_n}.tpath")" \
        || { guard_fail "${_n}: the manifest records no link-target path"; return 1; }
    if [[ -z "${_tp}" ]]; then
        [[ ! -e "${_p}" ]] \
            || { guard_fail "${_n}: manifest recorded a dangling link but it resolves now"; return 1; }
        return 0
    fi
    _cfgbk_revalidate_target "${_n}" "${_tp}"
}

_cfgbk_revalidate_absent() {
    local _n="$1" _p="$2" _bp="$3" _state="$4"
    { [[ ! -e "${_bp}" ]] && [[ ! -L "${_bp}" ]]; } \
        || { guard_fail "${_n}: manifest says ${_state} but a backup file exists"; return 1; }
    if [[ "${_state}" == absent-file ]]; then
        [[ -d "${CFGBK_C}/${_n}" ]] \
            || { guard_fail "${_n}: config dir vanished since step 1"; return 1; }
        [[ "$(guard_path_type "${_p}")" == absent ]] \
            || { guard_fail "${_n}: a config appeared since step 1"; return 1; }
        return 0
    fi
    [[ ! -e "${CFGBK_C}/${_n}" ]] \
        || { guard_fail "${_n}: config dir appeared since step 1"; return 1; }
}

cfgbk_revalidate() {
    local _n _p _bp _s
    [[ -f "${CFGBK_B}/manifest" ]] \
        || { guard_fail "no published manifest at ${CFGBK_B}/manifest -- step 1 did not finish; nothing applied"; return 1; }
    [[ ! -e "${CFGBK_B}/manifest.partial" ]] \
        || { guard_fail "${CFGBK_B}/manifest.partial still present -- step 1 is half-done"; return 1; }
    cfgbk_states_ok "${CFGBK_B}/manifest" || return 1
    for _n in "${CFGBK_NAMES[@]}"; do
        _p="${CFGBK_C}/${_n}/config"
        _bp="${CFGBK_B}/${_n}.config"
        _s="$(guard_field "${CFGBK_B}" "${_n}")" \
            || { guard_fail "${_n}: cannot read the manifest state"; return 1; }
        case "${_s}" in
            regular) _cfgbk_revalidate_regular "${_n}" "${_p}" "${_bp}" || return 1 ;;
            symlink) _cfgbk_revalidate_symlink "${_n}" "${_p}" "${_bp}" || return 1 ;;
            absent-file | absent-dir)
                _cfgbk_revalidate_absent "${_n}" "${_p}" "${_bp}" "${_s}" || return 1
                ;;
            *) guard_fail "${_n}: unknown manifest state '${_s}'"; return 1 ;;
        esac
    done
    return 0
}

# --- step 3: restore ---------------------------------------------------------

_cfgbk_restore_link() {
    local _n="$1" _p="$2" _plink _mlink _tp _sha _msha
    _plink="$(readlink -- "${_p}")" \
        || { guard_fail "${_n}: cannot read the restored link"; return 1; }
    _mlink="$(guard_field "${CFGBK_B}" "${_n}.link")" \
        || { guard_fail "${_n}: the manifest records no link target"; return 1; }
    [[ "${_plink}" == "${_mlink}" ]] \
        || { guard_fail "${_n}: restored link points at ${_plink}"; return 1; }
    _tp="$(guard_field "${CFGBK_B}" "${_n}.tpath")" \
        || { guard_fail "${_n}: the manifest records no link-target path"; return 1; }
    [[ -n "${_tp}" ]] || return 0
    # Put the pointed-to file back byte for byte, whether setup wrote through
    # the link or replaced it (cp -a over an untouched file is a no-op).
    cp -a -- "${CFGBK_B}/${_n}.target" "${_tp}" \
        || { guard_fail "${_n}: restoring link target ${_tp} failed"; return 1; }
    _sha="$(guard_sha256 "${_tp}")" \
        || { guard_fail "${_n}: hashing the restored link target failed"; return 1; }
    _msha="$(guard_field "${CFGBK_B}" "${_n}.tsha")" \
        || { guard_fail "${_n}: the manifest records no link-target checksum"; return 1; }
    [[ "${_sha}" == "${_msha}" ]] \
        || { guard_fail "${_n}: link target ${_tp} not restored byte for byte"; return 1; }
}

_cfgbk_restore_file() {
    local _n="$1" _p="$2" _bp="$3" _s="$4" _t _sha _msha
    mkdir -p -- "${CFGBK_C}/${_n}" \
        || { guard_fail "${_n}: cannot recreate ${CFGBK_C}/${_n}"; return 1; }
    # Clear first: never write THROUGH a symlink.
    rm -f -- "${_p}" || { guard_fail "${_n}: cannot clear ${_p}"; return 1; }
    cp -a -- "${_bp}" "${_p}" || { guard_fail "${_n}: restore copy failed"; return 1; }
    _t="$(guard_path_type "${_p}")"
    [[ "${_t}" == "${_s}" ]] \
        || { guard_fail "${_n}: restored as ${_t}, expected ${_s}"; return 1; }
    if [[ "${_s}" == symlink ]]; then
        _cfgbk_restore_link "${_n}" "${_p}"
        return
    fi
    _sha="$(guard_sha256 "${_p}")" \
        || { guard_fail "${_n}: hashing the restored config failed"; return 1; }
    _msha="$(guard_field "${CFGBK_B}" "${_n}.sha")" \
        || { guard_fail "${_n}: the manifest records no checksum"; return 1; }
    [[ "${_sha}" == "${_msha}" ]] \
        || { guard_fail "${_n}: restored content checksum mismatch"; return 1; }
}

cfgbk_restore_one() {
    local _n="$1" _p="${CFGBK_C}/$1/config" _bp="${CFGBK_B}/$1.config" _s
    _s="$(guard_field "${CFGBK_B}" "${_n}")" \
        || { guard_fail "${_n}: cannot read the manifest state"; return 1; }
    case "${_s}" in
        regular | symlink) _cfgbk_restore_file "${_n}" "${_p}" "${_bp}" "${_s}" ;;
        absent-file)
            rm -f -- "${_p}" || { guard_fail "${_n}: cannot remove ${_p}"; return 1; }
            [[ "$(guard_path_type "${_p}")" == absent ]] \
                || { guard_fail "${_n}: ${_p} still present"; return 1; }
            ;;
        absent-dir)
            rm -f -- "${_p}" || { guard_fail "${_n}: cannot remove ${_p}"; return 1; }
            rmdir -- "${CFGBK_C}/${_n}" 2>/dev/null
            [[ ! -e "${CFGBK_C}/${_n}" ]] \
                || { guard_fail "${_n}: ${CFGBK_C}/${_n} still present (not empty?)"; return 1; }
            ;;
        *) guard_fail "${_n}: unknown manifest state '${_s}'"; return 1 ;;
    esac
}

# Print `blocks=N` and fail unless N is 0.
#
# THE GUARD this whole item turns on: `grep -c` exits 1 for "zero matches" and
# >= 2 for "cannot read the file". Printing the latter as blocks=0 would state
# "the managed block is gone" on the strength of a file nobody read, so it is
# printed as -1 and fails instead.
cfgbk_report_blocks() {
    local _f="${CFGBK_C}/ghostty/config" _b=0
    if [[ "$(guard_path_type "${_f}")" != absent ]]; then
        _b="$(guard_count_lines "${_f}" 'BEGIN worktool managed block')" || {
            printf 'blocks=-1\n'
            guard_fail "cannot read ${_f} -- blocks= is not trustworthy"
            return 1
        }
    fi
    printf 'blocks=%s\n' "${_b}"
    [[ "${_b}" -eq 0 ]] \
        || { guard_fail "worktool managed block still present in ${_f}"; return 1; }
}

# Print `leftover-dirs=N` and fail unless N is 0. Same rule for the manifest
# read: grep's 1 is "this name is not absent-dir", >= 2 is "unreadable".
cfgbk_report_leftover_dirs() {
    local _lo=0 _n _rc
    for _n in "${CFGBK_NAMES[@]}"; do
        grep -qx -- "${_n}=absent-dir" "${CFGBK_B}/manifest"
        _rc=$?
        [[ "${_rc}" -le 1 ]] \
            || { guard_fail "cannot read ${CFGBK_B}/manifest -- leftover-dirs= is not trustworthy"; return 1; }
        [[ "${_rc}" -eq 0 ]] || continue
        [[ ! -e "${CFGBK_C}/${_n}" ]] || _lo=$((_lo + 1))
    done
    printf 'leftover-dirs=%s\n' "${_lo}"
    [[ "${_lo}" -eq 0 ]] \
        || { guard_fail "directories that did not exist before are still there"; return 1; }
}
