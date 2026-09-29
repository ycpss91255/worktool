#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/config_spec.bats - lib/config.sh: the ONE owner of the worktool
# state file, issue #199 rounds 3-5.
#
# Contract under test:
#   - Only lib/config.sh knows where the state file is
#     ($XDG_CONFIG_HOME/worktool/config). No other module handles the path:
#     every public function works on THE state file and takes no path, and
#     messages naming it go through config_log / config_say / config_fill.
#   - config_get <key>: the value of the FIRST `<key>=` line (a bare `<key>`
#     line reads as empty); nothing for an absent file or key.
#   - config_get_all <key>: every `<key>=` value, in file order.
#   - config_each <fn> [args]: calls `<fn> [args] <lineno> <key>
#     <has_value 0|1> <value>` for every line that is not a comment or
#     blank; stops at (and returns) the first non-zero status.
#   - config_exists: 0 when the state file exists.
#   - config_set <key> <value> [<key> <value> ...]: each given key is set
#     IN PLACE - its first line is replaced, any later line of the same key
#     is dropped (the writer owns that key) - and a key the file does not
#     hold yet is appended, in argument order. Every other byte stays:
#     comments, blank and whitespace-only lines, keys of other writers and
#     of later versions, their duplicates, CRLF line endings, trailing
#     blank lines and a missing final newline (a newline is only added
#     before an appended key, to separate it). A new file starts with one
#     comment header. Atomic (temp file + rename), keeps the file's mode,
#     serialised by a lock (flock, else a PID-stamped mkdir lock whose
#     stale holder is broken), so two concurrent calls both land.
#   - config_write_atomic <file>: replace <file> with stdin atomically,
#     keeping an existing file's mode (for the other files worktool writes).
#
# Every file comparison is byte-exact (cmp against an expected file):
# `run cat` / `$(...)` drop trailing newlines and could not see the
# framing this contract promises to keep. test/unit/config_mutation_spec
# proves these cases fail on broken copies of lib/config.sh.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CONFIG_HOME
    mkdir -p "${HOME}"
    CONFIG="${HOME}/.config/worktool/config"
    EXPECTED="${BATS_TEST_TMPDIR}/expected"
    # shellcheck source=../../lib/log.sh
    source "${LIB_DIR}/log.sh"
    # shellcheck source=../../lib/config.sh
    source "${LIB_DIR}/config.sh"
}

# Write file $1 from string $2 with backslash escapes (\n, \r) expanded, so
# the exact bytes - final newline or not - are what the case says.
_bytes() {
    mkdir -p "$(dirname -- "$1")"
    printf '%b' "$2" >"$1"
}

# Byte-exact comparison of the state file with the expected file.
_assert_bytes() {
    run cmp -- "${EXPECTED}" "${CONFIG}"
    assert_success
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# --- location ------------------------------------------------------------------

@test "the state file is \$XDG_CONFIG_HOME/worktool/config, else ~/.config/worktool/config" {
    run config_set k v
    assert_success
    assert [ -f "${CONFIG}" ]
    run config_exists
    assert_success
    XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/xdg" run config_set k v
    assert_success
    assert [ -f "${BATS_TEST_TMPDIR}/xdg/worktool/config" ]
    rm -f "${CONFIG}"
    run config_exists
    assert_failure
}

@test "config_log / config_say / config_fill name the state file without handing out its path" {
    run --separate-stderr config_log error "" ": broken"
    assert_success
    assert_equal "${stderr:-}" "[ERROR] ${CONFIG}: broken"
    run config_say "config: " " (not found)"
    assert_output "config: ${CONFIG} (not found)"
    run config_fill <<<"state: {state-file} and {state-file}"
    assert_output "state: \$XDG_CONFIG_HOME/worktool/config and \$XDG_CONFIG_HOME/worktool/config"
}

# The only place that may name the state file: lib/config.sh. Structural
# proof: the path fragment and the internal path function appear in no
# other file under lib/, script/ or box/ - code that cannot name the file
# cannot open it. $1 is the tree to check; prints the offending files.
_foreign_owners() {
    grep -rlE 'worktool/config|_config_file' "$1/lib" "$1/script" "$1/box" \
        | grep -vxF "$1/lib/config.sh"
}

@test "only lib/config.sh can name the state file (lib/ script/ box/)" {
    run _foreign_owners "${REPO_ROOT}"
    assert_output ""
}

@test "the ownership check catches a module that names the state file" {
    local _tree="${BATS_TEST_TMPDIR}/tree"
    mkdir -p "${_tree}/lib" "${_tree}/script" "${_tree}/box"
    printf '%s\n' '_config_file() { :; }' >"${_tree}/lib/config.sh"
    printf '%s\n' "cat \"\$HOME/.config/worktool/config\"" >"${_tree}/script/rogue.sh"
    printf '%s\n' "x=\$(_config_file)" >"${_tree}/lib/sneaky.sh"
    run _foreign_owners "${_tree}"
    assert_line "${_tree}/script/rogue.sh"
    assert_line "${_tree}/lib/sneaky.sh"
    refute_line "${_tree}/lib/config.sh"
}

# --- reading -----------------------------------------------------------------

@test "config_get reads the first occurrence; absent file or key reads as nothing" {
    run config_get tmux
    assert_success
    assert_output ""
    _bytes "${CONFIG}" '# c\ntmux=host\ntmux=inside\nhome\npath=/a=b'
    run config_get tmux
    assert_output "host"
    run config_get path
    assert_output "/a=b"
    run config_get home
    assert_output ""
    run config_get box
    assert_output ""
}

@test "config_get_all reads every occurrence in file order, the last line without a newline too" {
    _bytes "${CONFIG}" 'link=~/.aws\n# link=no\nlinks=no\nlink=.b\nlink=.c'
    local _t='~'
    run config_get_all link
    assert_success
    assert_output "$(printf '%s\n' "${_t}/.aws" .b .c)"
}

# Records every config_each call, one line each.
_record() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"; }

@test "config_each passes line number, key, has-value and value of every entry; comments and blanks skipped" {
    _bytes "${CONFIG}" '# c\n\ntmux=host\n   \nhome\n  # indented\nfuture=a = b\nlast=x'
    run config_each _record
    assert_success
    assert_output "$(printf '%s\n' '3|tmux|1|host' '5|home|0|' '7|future|1|a = b' '8|last|1|x')"
}

_stop_at_home() { [[ "$2" != home ]] || { echo "stop at $1"; return 3; }; }

@test "config_each stops at the first failing callback and returns its status" {
    _bytes "${CONFIG}" 'tmux=host\nhome=/x\nbox=dev\n'
    run config_each _stop_at_home
    assert_failure 3
    assert_output "stop at 2"
}

# --- writing: in place, byte-exact -------------------------------------------

@test "config_set replaces its keys in place, drops their duplicates, appends new keys, keeps every other line" {
    _bytes "${CONFIG}" '# notes\n\nlink=~/.aws\ntmux=host\nfuture=x = y\nlink=~/.aws\ntmux=inside\nhome\n  \n# end\n'
    _bytes "${EXPECTED}" '# notes\n\nlink=~/.aws\ntmux=inside\nfuture=x = y\nlink=~/.aws\nhome=/srv/box\n  \n# end\nhome.source=user\n'
    run config_set tmux inside home /srv/box home.source user
    assert_success
    _assert_bytes
}

# EOF framings, one `<name>|<tail>` per line; the tail is a printf %b
# string ending the file.
_framings() {
    printf '%s\n' \
        'nl|link=.a\n' \
        'nonl|link=.a' \
        'blanks|link=.a\n\n\n' \
        'ws|link=.a\n  \t ' \
        'crlf|link=.a\r\n# c\r\n' \
        'crlf-nonl|link=.a\r\n# c\r' \
        'crlf-blanks|link=.a\r\n\r\n\r\n' \
        'crlf-ws|link=.a\r\n  \t \r'
}

@test "config_set replace-only keeps every EOF framing byte-for-byte" {
    local _name _tail
    while IFS='|' read -r _name _tail; do
        _bytes "${CONFIG}" "# h\nhome=/old\n${_tail}"
        _bytes "${EXPECTED}" "# h\nhome=/new\n${_tail}"
        run config_set home /new
        assert_success
        run cmp -- "${EXPECTED}" "${CONFIG}"
        [[ "${status}" -eq 0 ]] || fail "framing ${_name}: ${output}"
    done < <(_framings)
}

@test "config_set replace-only keeps a missing final newline on its own last line" {
    _bytes "${CONFIG}" 'link=~/.aws\nhome=/old'
    _bytes "${EXPECTED}" 'link=~/.aws\nhome=/new'
    run config_set home /new
    assert_success
    _assert_bytes
}

@test "config_set appending keeps every EOF framing and separates a last line without a newline" {
    local _name _tail _sep
    while IFS='|' read -r _name _tail; do
        _sep=''
        [[ "${_tail}" == *'\n' ]] || _sep='\n'
        _bytes "${CONFIG}" "# h\n${_tail}"
        _bytes "${EXPECTED}" "# h\n${_tail}${_sep}home=/new\n"
        run config_set home /new
        assert_success
        run cmp -- "${EXPECTED}" "${CONFIG}"
        [[ "${status}" -eq 0 ]] || fail "framing ${_name}: ${output}"
    done < <(_framings)
}

@test "config_set keeps backslashes and spaces verbatim" {
    _bytes "${CONFIG}" 'note=a\\tb \\\\ c\nbox=dev\n'
    printf '%s\n' 'note=a\tb \\ c' 'box=dev' 'home=/srv/my \n box' >"${EXPECTED}"
    run config_set home '/srv/my \n box'
    assert_success
    _assert_bytes
}

@test "config_set creates a missing file (and its directory) with a header" {
    run config_set home /srv/box home.source default
    assert_success
    {
        head -n 1 "${CONFIG}"
        printf '%s\n' home=/srv/box home.source=default
    } >"${EXPECTED}"
    _assert_bytes
    run head -n 1 "${CONFIG}"
    assert_output --regexp '^# worktool state'
}

@test "config_set keeps the file's mode and leaves only the file behind" {
    _bytes "${CONFIG}" 'tmux=host\n'
    chmod 0640 "${CONFIG}"
    run config_set tmux inside
    assert_success
    assert_equal "$(stat -c %a "${CONFIG}")" "640"
    run ls -A "$(dirname -- "${CONFIG}")"
    assert_output "config"
}

@test "config_set with an odd number of arguments is refused and writes nothing" {
    _bytes "${CONFIG}" 'tmux=host'
    cp "${CONFIG}" "${EXPECTED}"
    run config_set tmux
    assert_failure
    _assert_bytes
}

@test "config_write_atomic replaces the file with stdin byte-for-byte and keeps its mode" {
    local _f="${BATS_TEST_TMPDIR}/other"
    _bytes "${_f}" 'old\n'
    chmod 0604 "${_f}"
    _bytes "${EXPECTED}" 'new\n\n'
    run config_write_atomic "${_f}" <"${EXPECTED}"
    assert_success
    run cmp -- "${EXPECTED}" "${_f}"
    assert_success
    assert_equal "$(stat -c %a "${_f}")" "604"
}

# --- concurrency ---------------------------------------------------------------

# Two writers of different keys, many rounds. A barrier makes each round
# deterministic: both writers are forked first and wait for the same go
# file, so they reach config_set together. With the read-modify-rename
# serialised every write lands; without it one writer's rename erases the
# other's key.
_race() {
    local _i _go
    for _i in $(seq 1 30); do
        _go="${BATS_TEST_TMPDIR}/go.${_i}"
        (until [[ -e "${_go}" ]]; do sleep 0.01; done; config_set "$1" "v${_i}") &
        (until [[ -e "${_go}" ]]; do sleep 0.01; done; config_set "$2" "v${_i}") &
        : >"${_go}"
        wait
        [[ "$(config_get "$1")" == "v${_i}" && "$(config_get "$2")" == "v${_i}" ]] \
            || { echo "lost a write in round ${_i}"; return 1; }
    done
}

@test "two concurrent config_set calls both land (flock)" {
    _bytes "${CONFIG}" '# shared\n'
    run _race home box
    assert_success
}

@test "two concurrent config_set calls both land without flock (mkdir lock)" {
    _config_have_flock() { return 1; }
    _bytes "${CONFIG}" '# shared\n'
    run _race home box
    assert_success
    assert [ ! -e "${CONFIG}.lock" ]
}

@test "a stale mkdir lock whose PID is gone is broken; a live one is waited for, then refused" {
    _config_have_flock() { return 1; }
    local _dead
    sh -c 'exit 0' &
    _dead=$!
    wait "${_dead}"
    _bytes "${CONFIG}" 'home=/old\n'
    mkdir "${CONFIG}.lock"
    printf '%s\n' "${_dead}" >"${CONFIG}.lock/pid"
    run config_set home /new
    assert_success
    _bytes "${EXPECTED}" 'home=/new\n'
    _assert_bytes
    assert [ ! -e "${CONFIG}.lock" ]
    # A lock held by a live process is not broken: the writer waits, then
    # gives up (bounded), writing nothing.
    mkdir "${CONFIG}.lock"
    printf '%s\n' "$$" >"${CONFIG}.lock/pid"
    CONFIG_LOCK_TRIES=5 run config_set home /other
    assert_failure 1
    _assert_bytes
    assert [ -d "${CONFIG}.lock" ]
    rm -rf "${CONFIG}.lock"
}
