#!/usr/bin/env bats
# test/unit/config_mutation_spec.bats - the state-file specs can SEE every
# property lib/config.sh claims (issue #199 rounds 5-6).
#
# A spec that passes on a broken implementation proves nothing (round 3's
# EOF cases compared through `run cat`; round 4's setup matrix always
# appended; round 5's `unknown` mutant also changed the final newline, so
# a case could "kill" it for the wrong reason). This spec drives one table:
#
#   property -> mutant -> the spec cases that must FAIL on it
#
# Each mutant breaks exactly ONE property of lib/config.sh (or, for
# `owner`, of the ownership rule) and is appended to a copy of the repo
# (later definitions win); the listed cases run against the copy with a
# nested bats and must fail. Two guards keep the table honest:
#   - control: every listed case passes on the unmutated copy, so a
#     failure is the mutant's doing;
#   - purity: on a fixture that holds everything EXCEPT the element its
#     property is about, a mutant writes exactly the bytes the real
#     library writes - it cannot kill a case through a side effect. The
#     purity check itself is shown to catch the round-5 `unknown` mutant.
#
# The render mutants filter the real renderer's output with a pure-bash
# loop that keeps every line terminator, so they change only what their
# property names.

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

# property|mutant|spec|case-name regex
_table() {
    local _ip='config_set replaces its keys in place, drops their duplicates'
    local _ro='config_set replace-only keeps'
    local _s4='#199 r4: every setup run'
    local _s5='#199 r5: every setup run'
    local _a4='#199 r4: a recorded home'
    local _m _p
    printf '%s\n' \
        "EOF framing (missing final newline, trailing blank lines)|eof|unit/config_spec.bats|${_ro}" \
        "EOF framing (missing final newline, trailing blank lines)|eof|unit/setup_spec.bats|${_s5}" \
        "EOF framing (missing final newline, trailing blank lines)|eof|integration/assemble_spec.bats|${_a4}"
    for _m in comments blank crlf foreign-known unknown dup-foreign order; do
        _p="$(_property "${_m}")"
        printf '%s\n' \
            "${_p}|${_m}|unit/config_spec.bats|${_ip}" \
            "${_p}|${_m}|unit/setup_spec.bats|${_s4}" \
            "${_p}|${_m}|integration/assemble_spec.bats|${_a4}"
    done
    for _m in in-place dup-owned; do
        _p="$(_property "${_m}")"
        printf '%s\n' \
            "${_p}|${_m}|unit/config_spec.bats|${_ip}" \
            "${_p}|${_m}|unit/setup_spec.bats|${_s5}" \
            "${_p}|${_m}|integration/assemble_spec.bats|${_a4}"
    done
    printf '%s\n' \
        "file mode kept|mode|unit/config_spec.bats|config_set keeps the file's mode" \
        "file mode kept|mode|unit/setup_spec.bats|r3: setup keeps the state file's mode" \
        "file mode kept|mode|integration/assemble_spec.bats|r3: assemble keeps the state file's mode" \
        "atomic replace (rename)|atomic|unit/config_spec.bats|config_set replaces the file by rename" \
        "writes serialised (lock)|lock|unit/config_spec.bats|two concurrent config_set calls both land" \
        "only lib/config.sh reaches the state file|owner|unit/config_owner_spec.bats|read and write only the state file"
}

_property() {
    case "$1" in
        comments)      echo "comment lines kept" ;;
        blank)         echo "blank and whitespace-only lines kept" ;;
        crlf)          echo "CRLF line endings kept" ;;
        foreign-known) echo "other writers' known keys kept" ;;
        unknown)       echo "unknown keys kept" ;;
        dup-foreign)   echo "duplicated foreign lines kept" ;;
        order)         echo "foreign line order kept" ;;
        in-place)      echo "own keys replaced in place" ;;
        dup-owned)     echo "duplicates of own keys removed" ;;
    esac
}

# The neutral fixture of render mutant $1 (printf %b): comments, blank and
# whitespace-only lines, a CRLF line, known and unknown foreign keys, a
# duplicated foreign line, several foreign lines in order, a duplicated
# own key (home) and a last line without a newline - minus the element
# the mutant's property is about.
_neutral() {
    case "$1" in
        eof)           printf '%s' '# c\n\nhome=/old\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\n  \nhome=/old2\nlink=.z\n' ;;
        comments)      printf '%s' '\nhome=/old\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\n  \nhome=/old2\nlink=.z' ;;
        blank)         printf '%s' '# c\nhome=/old\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nhome=/old2\nlink=.z' ;;
        crlf)          printf '%s' '# c\n\nhome=/old\nlink=.a\nfuture=x\nlink=.a\nbox=dev\n  \nhome=/old2\nlink=.z' ;;
        foreign-known) printf '%s' '# c\n\nhome=/old\nfuture=x\n  \nhome=/old2\nlast=y' ;;
        unknown)       printf '%s' '# c\n\nhome=/old\nlink=.a\nlink=.a\nbox=dev\r\n  \nhome=/old2\nlink=.z' ;;
        dup-foreign)   printf '%s' '# c\n\nhome=/old\nlink=.a\nfuture=x\nbox=dev\r\n  \nhome=/old2\nlink=.z' ;;
        order)         printf '%s' '# c\n\nhome=/old\nfuture=x\n  \nhome=/old2\n# end' ;;
        in-place)      printf '%s' '# c\n\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\n  \nhome=/old' ;;
        dup-owned)     printf '%s' '# c\n\nhome=/old\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\n  \nlink=.z' ;;
        *)             printf '%s' '# c\n\nhome=/old\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\n  \nhome=/old2\nlink=.z' ;;
    esac
}

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

# The render-filter frame every render mutant shares: the real renderer's
# output is read line by line WITH each line's terminator (none for a last
# line without a newline) into L[] / E[], the mutant's _mut_transform edits
# them (seeing OWN[], the keys being set, and SRC, the file being
# rendered), and they are printed back byte for byte.
_frame() {
    cat <<'EOF'

# --- MUTANT frame (test/unit/config_mutation_spec.bats) ---
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
# Keep only the lines for which "$@" <line> succeeds.
_mut_keep() {
    local -a _l=() _e=(); local _i
    for _i in "${!L[@]}"; do
        if "$@" "${L[_i]}"; then _l+=("${L[_i]}"); _e+=("${E[_i]}"); fi
    done
    L=("${_l[@]}"); E=("${_e[@]}")
}
EOF
}

# Append mutant $1 to the copy.
_mutate() {
    local _cfg="${COPY}/lib/config.sh"
    case "$1" in
        eof)
            _frame >>"${_cfg}"
            cat >>"${_cfg}" <<'EOF'
_mut_transform() {
    local _n=${#L[@]}
    (( _n > 0 )) && E[_n - 1]=$'\n'
    while (( ${#L[@]} > 0 )) && [[ "${L[${#L[@]} - 1]}" =~ ^[[:space:]]*$ ]]; do
        unset 'L[${#L[@]}-1]' 'E[${#E[@]}-1]'
        L=("${L[@]}"); E=("${E[@]}")
    done
}
EOF
            ;;
        comments)
            _frame >>"${_cfg}"
            cat >>"${_cfg}" <<'EOF'
_mut_not_comment() { [[ ! "$1" =~ ^[[:space:]]*# ]]; }
_mut_transform() { _mut_keep _mut_not_comment; }
EOF
            ;;
        blank)
            _frame >>"${_cfg}"
            cat >>"${_cfg}" <<'EOF'
_mut_not_blank() { [[ ! "$1" =~ ^[[:space:]]*$ ]]; }
_mut_transform() { _mut_keep _mut_not_blank; }
EOF
            ;;
        crlf)
            _frame >>"${_cfg}"
            cat >>"${_cfg}" <<'EOF'
_mut_transform() { local _i; for _i in "${!L[@]}"; do L[_i]="${L[_i]%$'\r'}"; done; }
EOF
            ;;
        foreign-known)
            _frame >>"${_cfg}"
            cat >>"${_cfg}" <<'EOF'
_mut_not_fk() { ! { _mut_foreign "$1" && _mut_known "$1"; }; }
_mut_transform() { _mut_keep _mut_not_fk; }
EOF
            ;;
        unknown)
            _frame >>"${_cfg}"
            cat >>"${_cfg}" <<'EOF'
_mut_not_unknown() { ! { _mut_foreign "$1" && ! _mut_known "$1"; }; }
_mut_transform() { _mut_keep _mut_not_unknown; }
EOF
            ;;
        dup-foreign)
            _frame >>"${_cfg}"
            cat >>"${_cfg}" <<'EOF'
_mut_transform() {
    local -a _l=() _e=(); local _i _j _dup
    for _i in "${!L[@]}"; do
        _dup=0
        if _mut_foreign "${L[_i]}"; then
            for (( _j = 0; _j < _i; _j++ )); do
                [[ "${L[_j]}" == "${L[_i]}" ]] && _dup=1
            done
        fi
        (( _dup )) || { _l+=("${L[_i]}"); _e+=("${E[_i]}"); }
    done
    L=("${_l[@]}"); E=("${_e[@]}")
}
EOF
            ;;
        order)
            _frame >>"${_cfg}"
            cat >>"${_cfg}" <<'EOF'
_mut_transform() {
    local -a _idx=() _txt=(); local _i _n
    for _i in "${!L[@]}"; do
        _mut_foreign "${L[_i]}" && { _idx+=("${_i}"); _txt+=("${L[_i]}"); }
    done
    _n=${#_idx[@]}
    for (( _i = 0; _i < _n; _i++ )); do L[${_idx[_i]}]="${_txt[_n - 1 - _i]}"; done
}
EOF
            ;;
        in-place)
            _frame >>"${_cfg}"
            cat >>"${_cfg}" <<'EOF'
_mut_transform() {
    local -a _l=() _e=() _ol=() _oe=(); local _i
    for _i in "${!L[@]}"; do
        if _mut_own "${L[_i]}"; then _ol+=("${L[_i]}"); _oe+=("${E[_i]}")
        else _l+=("${L[_i]}"); _e+=("${E[_i]}"); fi
    done
    L=("${_l[@]}" "${_ol[@]}"); E=("${_e[@]}" "${_oe[@]}")
}
EOF
            ;;
        dup-owned)
            _frame >>"${_cfg}"
            cat >>"${_cfg}" <<'EOF'
# Keep the duplicates of each own key: as many extra copies of its (new)
# line, right after it, as the source file had extra lines of that key.
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
            ;;
        mode)
            printf '%s\n' '_config_copy_mode() { :; }' >>"${_cfg}"
            ;;
        atomic)
            cat >>"${_cfg}" <<'EOF'
# Same bytes, but written INTO the existing file instead of renamed over it.
_config_replace() {
    local _t="$1" _tmp
    shift
    mkdir -p -- "$(dirname -- "${_t}")" || return 1
    _tmp="$(mktemp)" || return 1
    "$@" >"${_tmp}" || { rm -f -- "${_tmp}"; return 1; }
    cat -- "${_tmp}" >"${_t}"
    rm -f -- "${_tmp}"
}
EOF
            ;;
        lock)
            printf '%s\n' '_config_locked() { shift; "$@"; }' >>"${_cfg}"
            ;;
        owner)
            # A module that builds the path itself, in a way no deny-list of
            # spellings would name.
            cat >>"${COPY}/lib/link.sh" <<'EOF'
link_entries() {
    local _p=worktool _l
    link_defaults
    while IFS= read -r _l || [[ -n "${_l}" ]]; do
        [[ "${_l}" == link=* ]] && printf '%s\n' "${_l#link=}"
    done <"$(config_xdg_dir)/${_p}/config"
}
EOF
            ;;
        unknown-grep)
            # The round-5 mutant: a grep pipeline, which also adds a missing
            # final newline. Kept to prove the purity check catches it.
            _frame >>"${_cfg}"
            cat >>"${_cfg}" <<'EOF'
_config_render() {
    _config_render_real "$@" \
        | grep -E '^(#|[[:space:]]*$|(auto-enter|terminal|tmux|box|home|link)(\.source)?(=|$))'
}
EOF
            ;;
    esac
}

# Run the cases of spec $1 (relative to test/) matching regex $2 against
# copy $3: TAP output in CASE_OUT, status in CASE_RC.
_run_cases() {
    CASE_RC=0
    CASE_OUT="$(bats --filter "$2" "$3/test/$1" 2>&1)" || CASE_RC=$?
}

# Mutant $1 must make every case the table lists for it fail.
_assert_caught() {
    local _p _m _spec _re _n=0
    _mutate "$1"
    while IFS='|' read -r _p _m _spec _re; do
        [[ "${_m}" == "$1" ]] || continue
        _n=$(( _n + 1 ))
        _run_cases "${_spec}" "${_re}" "${COPY}"
        grep -qE "^ok [0-9]+ " <<<"${CASE_OUT}" \
            && fail "mutant $1 (${_p}) survived a case of ${_spec} /${_re}/: ${CASE_OUT}"
        grep -qE "^not ok [0-9]+ " <<<"${CASE_OUT}" \
            || fail "mutant $1 (${_p}): ${_spec} /${_re}/ ran no case: ${CASE_OUT}"
    done < <(_table)
    (( _n > 0 )) || fail "mutant $1 has no row in the table"
}

# config_set home /new on the neutral fixture of mutant $2 with the library
# of tree $1; prints the resulting file's path.
_render_in() {
    local _f="${BATS_TEST_TMPDIR}/pure.${1##*/}.$2/state"
    mkdir -p "${_f%/*}"
    printf '%b' "$(_neutral "$2")" >"${_f}"
    WORKTOOL_CONFIG_FILE="${_f}" bash -c \
        'source "$1/lib/log.sh"; source "$1/lib/config.sh"; config_set home /new' _ "$1" \
        || return 1
    printf '%s\n' "${_f}"
}

# 0 when mutant $1 writes, on its neutral fixture, the real library's bytes.
_pure() {
    local _real _mut
    _mutate "$1"
    _real="$(_render_in "${CLEAN}" "$1")" || return 1
    _mut="$(_render_in "${COPY}" "$1")" || return 1
    cmp -s -- "${_real}" "${_mut}"
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "control: every case of the table passes on the unmutated copy" {
    local _p _m _spec _re
    while IFS='|' read -r _p _m _spec _re; do
        _run_cases "${_spec}" "${_re}" "${CLEAN}"
        [[ "${CASE_RC}" -eq 0 ]] || fail "control ${_spec} /${_re}/ failed: ${CASE_OUT}"
        grep -qE "^ok [0-9]+ " <<<"${CASE_OUT}" \
            || fail "control ${_spec} /${_re}/ ran no case: ${CASE_OUT}"
    done < <(_table | sort -t'|' -k3,4 -u)
}

@test "purity: every render/write mutant writes the real bytes where its property is absent" {
    local _m
    for _m in eof comments blank crlf foreign-known unknown dup-foreign order in-place dup-owned mode atomic lock; do
        rm -rf "${COPY}"
        cp -R "${CLEAN}" "${COPY}"
        _pure "${_m}" || fail "mutant ${_m} is not pure: it changes bytes outside its property"
    done
}

@test "purity: the check catches a mutant with a side effect (round 5's grep 'unknown')" {
    run _pure unknown-grep
    assert_failure
}

@test "mutant eof is caught" { _assert_caught eof; }
@test "mutant comments is caught" { _assert_caught comments; }
@test "mutant blank is caught" { _assert_caught blank; }
@test "mutant crlf is caught" { _assert_caught crlf; }
@test "mutant foreign-known is caught" { _assert_caught foreign-known; }
@test "mutant unknown is caught" { _assert_caught unknown; }
@test "mutant dup-foreign is caught" { _assert_caught dup-foreign; }
@test "mutant order is caught" { _assert_caught order; }
@test "mutant in-place is caught" { _assert_caught in-place; }
@test "mutant dup-owned is caught" { _assert_caught dup-owned; }
@test "mutant mode is caught" { _assert_caught mode; }
@test "mutant atomic is caught" { _assert_caught atomic; }
@test "mutant lock is caught" { _assert_caught lock; }
@test "mutant owner is caught" { _assert_caught owner; }
