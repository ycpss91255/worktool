#!/usr/bin/env bats
# test/unit/config_mutation_spec.bats - the state-file specs can SEE every
# property lib/config.sh claims (issue #199 rounds 5-7).
#
# The claim and the coverage are ONE list. lib/config.sh's header states
# its contract as `@prop <id>` lines; _rows below holds exactly one row per
# mutant, and each row names the property it breaks. A drift guard fails
# when the header's IDs and the table's IDs differ, so a property cannot be
# claimed without a mutant, nor a mutant added for an unclaimed property.
#
# A row: id | mutant | expected bytes after `config_set home /new` on ALL |
# expected bytes after `config_set home /new zz 1 yy 2` on ALL | cases.
#   mutant    the function below (_mut_<name>) that prints the mutant code;
#             appended to a copy of the repo (later definitions win)
#   expected  a printf %b string, or `=` for "exactly the real library's
#             bytes" - ALL (below) holds EVERY property's element at once,
#             so a mutant may change only its own element (purity)
#   cases     `<spec>@<case-name regex>` separated by `;`: each must FAIL
#             on the mutated copy (and pass on the clean one: control)
#
# Properties are disjoint by definition: `eof` is only the terminator of
# the final line (LF, CRLF, none); `blank` is blank and whitespace-only
# lines anywhere, trailing ones included. The eof mutant deletes no line;
# the blank mutant keeps the file's final terminator.
#
# The tests are generated from the table (bats_test_function), so adding a
# property touches one row.

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

# Every property's element at once: a comment, a blank and a
# whitespace-only line, an own key (home) not in last place and repeated,
# known foreign keys (link, box) with a duplicate and a CRLF line, an
# unknown key, several foreign lines in order, trailing blank lines and a
# final line without a terminator.
ALL='# c\n\n  \nhome=/old\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nhome=/old2\nlink=.z\n\n  '

_rows() {
    local _ip='unit/config_spec.bats@config_set replaces its keys in place, drops their duplicates'
    local _s4='unit/setup_spec.bats@#199 r4: every setup run'
    local _s5='unit/setup_spec.bats@#199 r5: every setup run'
    local _a4='integration/assemble_spec.bats@#199 r4: a recorded home'
    local _pres="${_ip};${_s4};${_a4}"
    local _own="${_ip};${_s5};${_a4}"
    local _cs='unit/config_spec.bats@'
    local _ow='unit/config_owner_spec.bats@owner: every'
    printf '%s\n' \
        "get-first|get_first|=|=|${_cs}config_get reads the first occurrence" \
        "get-bare|get_bare|=|=|${_cs}config_get reads the first occurrence" \
        "get-all|get_all|=|=|${_cs}config_get_all reads every occurrence" \
        "each-args|each_args|=|=|${_cs}config_each passes line number" \
        "each-skip|each_skip|=|=|${_cs}config_each passes line number" \
        "each-stop|each_stop|=|=|${_cs}config_each stops at the first failing callback" \
        "exists|exists|=|=|${_cs}the state file is" \
        "location|location|=|=|${_cs}the state file is" \
        "log|log|=|=|${_cs}config_log / config_say / config_fill" \
        "say|say|=|=|${_cs}config_log / config_say / config_fill" \
        "fill|fill|=|=|${_cs}config_log / config_say / config_fill" \
        "eof|eof|# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  \n|=|${_cs}config_set replace-only keeps;${_s5};${_a4}" \
        "blank|blank|# c\nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z|# c\nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\nzz=1\nyy=2\n|${_pres}" \
        "comments|comments|\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  |\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  \nzz=1\nyy=2\n|${_pres}" \
        "crlf|crlf|# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\nlink=.z\n\n  |# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\nlink=.z\n\n  \nzz=1\nyy=2\n|${_pres}" \
        "foreign-known|foreign_known|# c\n\n  \nhome=/new\nfuture=x\n\n  |# c\n\n  \nhome=/new\nfuture=x\n\n  \nzz=1\nyy=2\n|${_pres}" \
        "unknown|unknown|# c\n\n  \nhome=/new\nlink=.a\nlink=.a\nbox=dev\r\nlink=.z\n\n  |# c\n\n  \nhome=/new\nlink=.a\nlink=.a\nbox=dev\r\nlink=.z\n\n  \nzz=1\nyy=2\n|${_pres}" \
        "dup-foreign|dup_foreign|# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nbox=dev\r\nlink=.z\n\n  |# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nbox=dev\r\nlink=.z\n\n  \nzz=1\nyy=2\n|${_pres}" \
        "order|order|# c\n\n  \nhome=/new\nlink=.z\nbox=dev\r\nlink=.a\nfuture=x\nlink=.a\n\n  |# c\n\n  \nhome=/new\nlink=.z\nbox=dev\r\nlink=.a\nfuture=x\nlink=.a\n\n  \nzz=1\nyy=2\n|${_pres}" \
        "in-place|in_place|# c\n\n  \nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  \nhome=/new|# c\n\n  \nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  \nhome=/new\nzz=1\nyy=2\n|${_own}" \
        "dup-owned|dup_owned|# c\n\n  \nhome=/new\nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  |# c\n\n  \nhome=/new\nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  \nzz=1\nyy=2\n|${_own}" \
        "append-order|append_order|=|# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  \nyy=2\nzz=1\n|${_ip};${_s4}" \
        "append-sep|append_sep|=|# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  zz=1\nyy=2\n|${_cs}config_set appending keeps every EOF framing;${_s4}" \
        "new-header|new_header|=|=|${_cs}config_set creates a missing file" \
        "odd-args|odd_args|=|=|${_cs}config_set with an odd number of arguments" \
        "fail-nothing|fail_nothing|=|=|${_cs}a failing render writes nothing" \
        "atomic|atomic|=|=|${_cs}config_set replaces the file by rename" \
        "mode|mode|=|=|${_cs}config_set keeps the file.s mode;unit/setup_spec.bats@r3: setup keeps the state file.s mode;integration/assemble_spec.bats@r3: assemble keeps the state file.s mode" \
        "lock|lock|=|=|${_cs}two concurrent config_set calls both land" \
        "no-flock|no_flock|=|=|${_cs}without flock" \
        "wa-atomic|wa_atomic|=|=|${_cs}config_write_atomic replaces by rename" \
        "wa-mode|wa_mode|=|=|${_cs}config_write_atomic replaces the file with stdin" \
        "owner|owner_link|=|=|${_ow} assemble row" \
        "owner|owner_enter|=|=|${_ow} setup row;${_ow} status row" \
        "owner|owner_home|=|=|${_ow} assemble row" \
        "owner|owner_setup_restore|=|=|${_ow} setup row" \
        "owner|owner_assemble_existing|=|=|${_ow} assemble row" \
        "owner|owner_status|=|=|${_ow} status row"
}

# --- mutants: each prints the code to add, first line `#> <file>` (append)
# or `#^ <file>` (insert before the script's run guard) ----------------------

# The render frame the render mutants share: the real renderer's output is
# read WITH each line's terminator into L[] / E[], _mut_transform edits them
# (seeing OWN[] - the keys being set - and SRC, the file being rendered),
# and they are printed back byte for byte.
_frame() {
    cat <<'EOF'
eval "$(declare -f _config_render | sed '1s/^_config_render /_config_render_real /')"
_config_render() { _config_render_real "$@" | _mut_filter "$@"; }
_mut_filter() {
    local -a L=() E=() OWN=()
    local SRC="$1" _line _eol _i
    shift
    while (( $# )); do OWN+=("$1"); shift 2; done
    while :; do
        _eol=$'\n'
        if ! IFS= read -r _line; then
            [[ -n "${_line}" ]] || break
            _eol=''
        fi
        L+=("${_line}"); E+=("${_eol}")
        [[ -n "${_eol}" ]] || break
    done
    _mut_transform
    for _i in "${!L[@]}"; do printf '%s%s' "${L[_i]}" "${E[_i]}"; done
}
_mut_key() { printf '%s' "${1%%=*}"; }
_mut_meta() { [[ "$1" =~ ^[[:space:]]*(#|$) ]]; }
_mut_own() { local _k; for _k in "${OWN[@]}"; do [[ "$(_mut_key "$1")" == "${_k}" ]] && return 0; done; return 1; }
_mut_known() { [[ "$(_mut_key "$1")" =~ ^(auto-enter|terminal|tmux|box|home|link)(\.source)?$ ]]; }
_mut_foreign() { ! _mut_meta "$1" && ! _mut_own "$1"; }
_mut_in_src() { local _l; while IFS= read -r _l || [[ -n "${_l}" ]]; do [[ "$(_mut_key "${_l}")" == "$1" ]] && return 0; done <"${SRC}"; return 1; }
# Keep only the lines for which "$@" <line> succeeds; the file keeps its
# final terminator (a dropped last line hands it to the new last line).
_mut_keep() {
    local -a _l=() _e=(); local _i _fin="${E[${#E[@]}-1]:-}"
    for _i in "${!L[@]}"; do
        if "$@" "${L[_i]}"; then _l+=("${L[_i]}"); _e+=("${E[_i]}"); fi
    done
    L=("${_l[@]}"); E=("${_e[@]}")
    _mut_final "${_fin}"
}
# Give every line but the last a newline and the last one terminator $1.
_mut_final() {
    local _i _n=${#L[@]}
    for (( _i = 0; _i < _n - 1; _i++ )); do [[ -n "${E[_i]}" ]] || E[_i]=$'\n'; done
    (( _n == 0 )) || E[_n - 1]="$1"
}
EOF
}

_mut_get_first() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
# Returns the LAST occurrence.
config_get() {
    local _v="" _f=0 _l
    while IFS= read -r _l || [[ -n "${_l}" ]]; do
        if [[ "${_l}" == "$1" ]]; then _v=""; _f=1
        elif [[ "${_l}" == "$1="* ]]; then _v="${_l#"$1="}"; _f=1; fi
    done < <(cat -- "$(_config_file)" 2>/dev/null)
    (( _f == 0 )) || printf '%s\n' "${_v}"
}
EOF
}
_mut_get_bare() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
# A bare `<key>` line does not count as an occurrence.
_config_get_line() { [[ "$3" == "$1="* ]] || return 0; printf '%s\n' "${3#"$1="}"; return 10; }
EOF
}
_mut_get_all() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
_config_get_all_line() { [[ "$3" == "$1="* ]] || return 0; printf '%s\n' "${3#"$1="}"; return 10; }
config_get_all() { local _r=0; _config_lines "$(_config_file)" _config_get_all_line "$1" || _r=$?; return 0; }
EOF
}
_mut_each_args() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
_config_each_line() {
    local _line="${*: -1}" _n="${*: -2:1}"
    local -a _cb=("${@:1:$#-2}")
    [[ "${_line}" =~ ^[[:space:]]*(#|$) ]] && return 0
    "${_cb[@]}" "${_n}" "${_line%%=*}" 1 "${_line#*=}"
}
EOF
}
_mut_each_skip() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
_config_each_line() {
    local _line="${*: -1}" _n="${*: -2:1}"
    local -a _cb=("${@:1:$#-2}")
    if [[ "${_line}" == *=* ]]; then "${_cb[@]}" "${_n}" "${_line%%=*}" 1 "${_line#*=}"
    else "${_cb[@]}" "${_n}" "${_line}" 0 ""; fi
}
EOF
}
_mut_each_stop() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
_mut_nostop() { _config_each_line "$@" || :; }
config_each() { _config_lines "$(_config_file)" _mut_nostop "$@"; }
EOF
}
_mut_exists() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
config_exists() { return 0; }
EOF
}
_mut_location() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
# XDG_CONFIG_HOME is ignored.
config_xdg_dir() { printf '%s/.config\n' "${HOME}"; }
EOF
}
_mut_log() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
config_log() { "log_$1" "$2${3:-}"; }
EOF
}
_mut_say() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
config_say() { printf '%s%s\n' "$1" "${2:-}"; }
EOF
}
_mut_fill() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
config_fill() { cat; }
EOF
}

_mut_eof() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
_mut_transform() { (( ${#L[@]} == 0 )) || E[${#L[@]} - 1]=$'\n'; }
EOF
}
_mut_blank() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
_mut_nb() { [[ ! "$1" =~ ^[[:space:]]*$ ]]; }
_mut_transform() { _mut_keep _mut_nb; }
EOF
}
_mut_comments() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
_mut_nc() { [[ ! "$1" =~ ^[[:space:]]*# ]]; }
_mut_transform() { _mut_keep _mut_nc; }
EOF
}
_mut_crlf() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
# Every line but the last loses a trailing CR.
_mut_transform() { local _i; for (( _i = 0; _i < ${#L[@]} - 1; _i++ )); do L[_i]="${L[_i]%$'\r'}"; done; }
EOF
}
_mut_foreign_known() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
_mut_nfk() { ! { _mut_foreign "$1" && _mut_known "$1"; }; }
_mut_transform() { _mut_keep _mut_nfk; }
EOF
}
_mut_unknown() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
_mut_nu() { ! { _mut_foreign "$1" && ! _mut_known "$1"; }; }
_mut_transform() { _mut_keep _mut_nu; }
EOF
}
_mut_dup_foreign() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
_mut_transform() {
    local -a _l=() _e=(); local _i _j _dup _fin="${E[${#E[@]}-1]:-}"
    for _i in "${!L[@]}"; do
        _dup=0
        if _mut_foreign "${L[_i]}"; then
            for (( _j = 0; _j < _i; _j++ )); do [[ "${L[_j]}" == "${L[_i]}" ]] && _dup=1; done
        fi
        (( _dup )) || { _l+=("${L[_i]}"); _e+=("${E[_i]}"); }
    done
    L=("${_l[@]}"); E=("${_e[@]}")
    _mut_final "${_fin}"
}
EOF
}
_mut_order() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
_mut_transform() {
    local -a _idx=() _txt=(); local _i _n
    for _i in "${!L[@]}"; do _mut_foreign "${L[_i]}" && { _idx+=("${_i}"); _txt+=("${L[_i]}"); }; done
    _n=${#_idx[@]}
    for (( _i = 0; _i < _n; _i++ )); do L[${_idx[_i]}]="${_txt[_n - 1 - _i]}"; done
}
EOF
}
_mut_in_place() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
# Own keys move to the end (the file keeps its final terminator).
_mut_transform() {
    local -a _l=() _e=() _ol=() _oe=(); local _i _fin="${E[${#E[@]}-1]:-}"
    for _i in "${!L[@]}"; do
        if _mut_own "${L[_i]}"; then _ol+=("${L[_i]}"); _oe+=("${E[_i]}")
        else _l+=("${L[_i]}"); _e+=("${E[_i]}"); fi
    done
    L=("${_l[@]}" "${_ol[@]}"); E=("${_e[@]}" "${_oe[@]}")
    _mut_final "${_fin}"
}
EOF
}
_mut_dup_owned() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
# Each own key keeps as many lines as the source had.
_mut_transform() {
    local -a _l=() _e=(); local _i _k _n _line
    for _i in "${!L[@]}"; do
        _l+=("${L[_i]}"); _e+=("${E[_i]}")
        _mut_own "${L[_i]}" || continue
        _k="$(_mut_key "${L[_i]}")"; _n=0
        while IFS= read -r _line || [[ -n "${_line}" ]]; do
            [[ "$(_mut_key "${_line}")" == "${_k}" ]] && _n=$(( _n + 1 ))
        done <"${SRC}"
        for (( ; _n > 1; _n-- )); do _l+=("${L[_i]}"); _e+=($'\n'); done
    done
    L=("${_l[@]}"); E=("${_e[@]}")
}
EOF
}
_mut_append_order() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
# The appended keys (own keys the source did not hold) come out reversed.
_mut_transform() {
    local -a _idx=() _txt=(); local _i _n
    [[ -f "${SRC}" ]] || return 0
    for _i in "${!L[@]}"; do
        if _mut_own "${L[_i]}" && ! _mut_in_src "$(_mut_key "${L[_i]}")"; then _idx+=("${_i}"); _txt+=("${L[_i]}"); fi
    done
    _n=${#_idx[@]}
    for (( _i = 0; _i < _n; _i++ )); do L[${_idx[_i]}]="${_txt[_n - 1 - _i]}"; done
}
EOF
}
_mut_append_sep() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
# No newline is added before the appended keys when the source's last
# line has none.
_mut_transform() {
    local _i _last=""
    [[ -f "${SRC}" && -s "${SRC}" ]] || return 0
    [[ "$(tail -c 1 -- "${SRC}" | od -An -c | tr -d ' ')" != '\n' ]] || return 0
    for _i in "${!L[@]}"; do
        if _mut_own "${L[_i]}" && ! _mut_in_src "$(_mut_key "${L[_i]}")"; then
            [[ -z "${_last}" ]] || E[_last]=''
            return 0
        fi
        _last="${_i}"
    done
}
EOF
}
_mut_new_header() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
_mut_transform() { [[ -e "${SRC}" ]] || { L=("${L[@]:1}"); E=("${E[@]:1}"); }; }
EOF
}
_mut_odd_args() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
eval "$(declare -f config_set | sed '1s/^config_set /_config_set_real /')"
config_set() { if (( $# % 2 )); then _config_set_real "$@" ""; else _config_set_real "$@"; fi; }
EOF
}
# A replace that ignores the render's status.
_mut_fail_nothing() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
_config_replace() {
    local _t="$1" _tmp
    shift
    mkdir -p -- "$(dirname -- "${_t}")" || return 1
    _tmp="$(mktemp "${_t}.XXXXXX")" || return 1
    "$@" >"${_tmp}"
    _config_copy_mode "${_t}" "${_tmp}"
    mv -f -- "${_tmp}" "${_t}"
}
EOF
}
# config_set writes INTO the existing file (same bytes, not atomic).
_mut_atomic() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
_mut_replace_inplace() {
    local _t="$1" _tmp
    shift
    _tmp="$(mktemp)" || return 1
    "$@" >"${_tmp}" || { rm -f -- "${_tmp}"; return 1; }
    cat -- "${_tmp}" >"${_t}"
    rm -f -- "${_tmp}"
}
eval "$(declare -f config_set | sed 's/_config_replace/_mut_replace_inplace/')"
EOF
}
# config_set renames without copying the mode.
_mut_mode() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
_mut_replace_nomode() {
    local _t="$1" _tmp
    shift
    _tmp="$(mktemp "${_t}.XXXXXX")" || return 1
    "$@" >"${_tmp}" || { rm -f -- "${_tmp}"; return 1; }
    mv -f -- "${_tmp}" "${_t}"
}
eval "$(declare -f config_set | sed 's/_config_replace/_mut_replace_nomode/')"
EOF
}
_mut_lock() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
eval "$(declare -f config_set | sed 's/_config_locked "${_file}" //')"
EOF
}
_mut_no_flock() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
eval "$(declare -f config_set | sed 's/! _config_have_flock/false/')"
EOF
}
_mut_wa_atomic() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
config_write_atomic() { mkdir -p -- "$(dirname -- "$1")" && cat >"$1"; }
EOF
}
_mut_wa_mode() {
    printf '#> lib/config.sh\n'
    cat <<'EOF'
config_write_atomic() {
    local _tmp
    mkdir -p -- "$(dirname -- "$1")" || return 1
    _tmp="$(mktemp "$1.XXXXXX")" || return 1
    cat >"${_tmp}" && mv -f -- "${_tmp}" "$1"
}
EOF
}

# --- owner mutants: a module that builds the path itself --------------------

_mut_owner_link() {
    printf '#> lib/link.sh\n'
    cat <<'EOF'
link_entries() {
    local _p=worktool _l
    link_defaults
    while IFS= read -r _l || [[ -n "${_l}" ]]; do
        [[ "${_l}" == link=* ]] && printf '%s\n' "${_l#link=}"
    done <"$(config_xdg_dir)/${_p}/config"
}
EOF
}
_mut_owner_enter() {
    printf '#> lib/enter.sh\n'
    cat <<'EOF'
eval "$(declare -f enter_config_check | sed '1s/^enter_config_check /_mut_ecc_real /')"
enter_config_check() { local _p=worktool; cat -- "$(config_xdg_dir)/${_p}/config" >&2; _mut_ecc_real "$@"; }
EOF
}
_mut_owner_home() {
    printf '#> lib/home.sh\n'
    cat <<'EOF'
eval "$(declare -f home_config_check | sed '1s/^home_config_check /_mut_hcc_real /')"
home_config_check() { local _p=worktool; printf 'home=/rogue\n' >>"$(config_xdg_dir)/${_p}/config"; _mut_hcc_real "$@"; }
EOF
}
# Only on setup's restore path (auto-enter no).
_mut_owner_setup_restore() {
    printf '#^ script/box/setup.sh\n'
    cat <<'EOF'
eval "$(declare -f _apply_disable | sed '1s/^_apply_disable /_mut_ad_real /')"
_apply_disable() { local _p=worktool; cat -- "$(config_xdg_dir)/${_p}/config" >&2; _mut_ad_real "$@"; }
EOF
}
# Only when the box already exists.
_mut_owner_assemble_existing() {
    printf '#^ script/box/assemble.sh\n'
    cat <<'EOF'
eval "$(declare -f _check_existing_box | sed '1s/^_check_existing_box /_mut_ceb_real /')"
_check_existing_box() {
    local _r=0 _p=worktool
    if home_of_box "${BOX_NAME}" >/dev/null 2>&1; then cat -- "$(config_xdg_dir)/${_p}/config" >&2; fi
    _mut_ceb_real "$@" || _r=$?
    return "${_r}"
}
EOF
}
_mut_owner_status() {
    printf '#^ script/box/status.sh\n'
    cat <<'EOF'
eval "$(declare -f _report_home | sed '1s/^_report_home /_mut_rh_real /')"
_report_home() { local _p=worktool; cat -- "$(config_xdg_dir)/${_p}/config"; _mut_rh_real "$@"; }
EOF
}

# --- legacy mutants the purity check must reject ----------------------------

# Round 5: a grep pipeline (also adds a missing final newline).
_mut_legacy_grep() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
_config_render() {
    _config_render_real "$@" \
        | grep -E '^(#|[[:space:]]*$|(auto-enter|terminal|tmux|box|home|link)(\.source)?(=|$))'
}
EOF
}
# Round 7: `eof` that also deleted trailing blank lines.
_mut_legacy_eof() {
    printf '#> lib/config.sh\n'; _frame
    cat <<'EOF'
_mut_transform() {
    local _n=${#L[@]}
    (( _n > 0 )) && E[_n - 1]=$'\n'
    while (( ${#L[@]} > 0 )) && [[ "${L[${#L[@]} - 1]}" =~ ^[[:space:]]*$ ]]; do
        unset 'L[${#L[@]}-1]' 'E[${#E[@]}-1]'
        L=("${L[@]}"); E=("${E[@]}")
    done
}
EOF
}

# --- machinery ---------------------------------------------------------------

setup_file() {
    CLEAN="${BATS_FILE_TMPDIR}/clean"
    mkdir -p "${CLEAN}"
    cp -R "${REPO_ROOT}/lib" "${REPO_ROOT}/script" "${REPO_ROOT}/test" \
        "${REPO_ROOT}/box" "${CLEAN}/"
    export CLEAN
}

setup() {
    COPY="${BATS_TEST_TMPDIR}/repo"
    cp -R "${CLEAN}" "${COPY}"
}

# Add mutant $1 (a _mut_ suffix) to the copy.
_mutate() {
    local _code _head _target
    _code="$("_mut_$1")"
    _head="${_code%%$'\n'*}"
    _code="${_code#*$'\n'}"
    _target="${COPY}/${_head#?? }"
    case "${_head}" in
        '#> '*) printf '\n%s\n' "${_code}" >>"${_target}" ;;
        '#^ '*)
            # Before the run guard: `if [[ "${BASH_SOURCE[0]:-}" == ...`.
            awk -v c="${_code}" \
                '/^if \[\[/ && index($0, "BASH_SOURCE[0]") && !done { print c; done = 1 } { print }' \
                "${_target}" >"${_target}.new"
            grep -qF -- "${_code%%$'\n'*}" "${_target}.new" || return 1
            cat "${_target}.new" >"${_target}"
            rm -f "${_target}.new"
            ;;
    esac
}

# Run the cases of `<spec>@<regex>` $1 against tree $2: TAP in CASE_OUT,
# status in CASE_RC.
_run_case() {
    CASE_RC=0
    CASE_OUT="$(bats --filter "${1#*@}" "$2/test/${1%%@*}" 2>&1)" || CASE_RC=$?
}

# The row of mutant $1.
_row() { _rows | awk -F'|' -v m="$1" '$2 == m'; }

_assert_caught() {
    local _id _m _r _a _cases _c
    IFS='|' read -r _id _m _r _a _cases <<<"$(_row "$1")"
    _mutate "$1"
    IFS=';' read -r -a _c <<<"${_cases}"
    for _c in "${_c[@]}"; do
        _run_case "${_c}" "${COPY}"
        grep -qE '^not ok [0-9]+ ' <<<"${CASE_OUT}" \
            || fail "mutant $1 (${_id}) was not caught by ${_c}: ${CASE_OUT}"
        ! grep -qE '^ok [0-9]+ ' <<<"${CASE_OUT}" \
            || fail "mutant $1 (${_id}) survived a case of ${_c}: ${CASE_OUT}"
    done
}

# Render ALL with the library of tree $1 and config_set args $2..; prints
# the resulting file's path.
_render_all() {
    local _tree="$1" _f
    shift
    _f="$(mktemp -d "${BATS_TEST_TMPDIR}/all.XXXXXX")/state"
    printf '%b' "${ALL}" >"${_f}"
    WORKTOOL_CONFIG_FILE="${_f}" bash -c \
        'source "$1/lib/log.sh"; source "$1/lib/config.sh"; shift; config_set "$@"' _ "${_tree}" "$@" \
        || return 1
    printf '%s\n' "${_f}"
}

# 0 when mutant $1 writes exactly expected bytes $2 (replace) and $3
# (append) on ALL; `=` means the real library's bytes.
_pure() {
    local _m="$1" _er="$2" _ea="$3" _got _want
    _mutate "${_m}" || return 1
    _got="$(_render_all "${COPY}" home /new)" || return 1
    if [[ "${_er}" == = ]]; then _want="$(_render_all "${CLEAN}" home /new)"
    else _want="${BATS_TEST_TMPDIR}/want.r"; printf '%b' "${_er}" >"${_want}"; fi
    cmp -s -- "${_want}" "${_got}" || return 1
    _got="$(_render_all "${COPY}" home /new zz 1 yy 2)" || return 1
    if [[ "${_ea}" == = ]]; then _want="$(_render_all "${CLEAN}" home /new zz 1 yy 2)"
    else _want="${BATS_TEST_TMPDIR}/want.a"; printf '%b' "${_ea}" >"${_want}"; fi
    cmp -s -- "${_want}" "${_got}"
}

_assert_pure() {
    local _id _m _r _a _cases
    IFS='|' read -r _id _m _r _a _cases <<<"$(_row "$1")"
    _pure "$1" "${_r}" "${_a}" \
        || fail "mutant $1 (${_id}) is not pure: on ALL it changes bytes outside its property"
}

# One caught-test and one purity-test per row.
while IFS='|' read -r _id _m _r _a _cases; do
    bats_test_function --description "mutant ${_m} (${_id}) is caught" -- _assert_caught "${_m}"
    bats_test_function --description "purity: mutant ${_m} (${_id}) changes only its own element" -- _assert_pure "${_m}"
done < <(_rows)

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "drift guard: lib/config.sh's @prop IDs are exactly the table's IDs" {
    local _claimed _covered
    _claimed="$(sed -n 's/^#[[:space:]]*@prop[[:space:]]\{1,\}\([a-z-]\{1,\}\).*/\1/p' "${REPO_ROOT}/lib/config.sh" | sort -u)"
    _covered="$(_rows | cut -d'|' -f1 | sort -u)"
    [[ -n "${_claimed}" ]] || fail "lib/config.sh claims no @prop"
    run diff <(printf '%s\n' "${_claimed}") <(printf '%s\n' "${_covered}")
    [[ "${status}" -eq 0 ]] || fail "claimed (<) and covered (>) properties differ: ${output}"
}

@test "drift guard: every row's mutant exists and every mutant has a row" {
    local _m _fns
    while IFS='|' read -r _ _m _ _ _; do
        declare -F "_mut_${_m}" >/dev/null || fail "row names a missing mutant: _mut_${_m}"
    done < <(_rows)
    _fns="$(declare -F | awk '{print $3}' | sed -n 's/^_mut_//p' | grep -v '^legacy_' | sort)"
    run diff <(printf '%s\n' "${_fns}") <(_rows | cut -d'|' -f2 | sort)
    [[ "${status}" -eq 0 ]] || fail "mutants without a row (<) / rows without a mutant (>): ${output}"
}

@test "control: every case of the table passes on the unmutated copy" {
    local _c
    while IFS= read -r _c; do
        _run_case "${_c}" "${CLEAN}"
        [[ "${CASE_RC}" -eq 0 ]] || fail "control ${_c} failed: ${CASE_OUT}"
        grep -qE '^ok [0-9]+ ' <<<"${CASE_OUT}" || fail "control ${_c} ran no case: ${CASE_OUT}"
    done < <(_rows | cut -d'|' -f5 | tr ';' '\n' | sort -u)
}

@test "purity: the check rejects round 5's grep mutant and round 7's eof mutant" {
    run _pure legacy_grep "$(_row unknown | cut -d'|' -f3)" "$(_row unknown | cut -d'|' -f4)"
    assert_failure
    rm -rf "${COPY}"; cp -R "${CLEAN}" "${COPY}"
    run _pure legacy_eof "$(_row eof | cut -d'|' -f3)" "$(_row eof | cut -d'|' -f4)"
    assert_failure
}
