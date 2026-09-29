#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/config_spec.bats - lib/config.sh: the ONE reader/writer of the
# worktool state file (~/.config/worktool/config), issue #199 rounds 3-4.
#
# Contract under test:
#   - config_get <file> <key>: the value of the FIRST `<key>=` line (a bare
#     `<key>` line reads as empty); nothing for an absent file or key.
#   - config_get_all <file> <key>: every `<key>=` value, in file order.
#   - config_each <file> <fn> [args]: calls `<fn> [args] <lineno> <key>
#     <has_value 0|1> <value>` for every line that is not a comment or
#     blank; stops at (and returns) the first non-zero status.
#   - config_set <file> <key> <value> [<key> <value> ...]: each given key
#     is set IN PLACE - its first line is replaced, any later line of the
#     same key is dropped (the writer owns that key) - and a key the file
#     does not hold yet is appended, in argument order. Every other byte
#     stays: comments, blank and whitespace-only lines, keys of other
#     writers and of later versions, their duplicates, CRLF line endings,
#     trailing blank lines and a missing final newline (a newline is only
#     added before an appended key, to separate it). A new file starts with
#     one comment header. The write is atomic (temp file in the same
#     directory, then rename), keeps the file's mode, and is serialised by
#     a lock, so two concurrent calls both land.
#   - config_write_atomic <file>: replace <file> with stdin atomically,
#     keeping an existing file's mode.
#   - Nothing else in lib/ or script/ reads or writes the state file itself.
#
# Every file comparison is byte-exact (cmp against an expected file):
# `run cat` / `$(...)` drop trailing newlines and could not see the
# framing this contract promises to keep.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    mkdir -p "${HOME}"
    CONFIG="${HOME}/.config/worktool/config"
    EXPECTED="${BATS_TEST_TMPDIR}/expected"
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

# --- reading -----------------------------------------------------------------

@test "config_get reads the first occurrence; absent file or key reads as nothing" {
    run config_get "${CONFIG}" tmux
    assert_success
    assert_output ""
    _bytes "${CONFIG}" '# c\ntmux=host\ntmux=inside\nhome\npath=/a=b'
    run config_get "${CONFIG}" tmux
    assert_output "host"
    run config_get "${CONFIG}" path
    assert_output "/a=b"
    run config_get "${CONFIG}" home
    assert_output ""
    run config_get "${CONFIG}" box
    assert_output ""
}

@test "config_get_all reads every occurrence in file order, the last line without a newline too" {
    _bytes "${CONFIG}" 'link=~/.aws\n# link=no\nlinks=no\nlink=.b\nlink=.c'
    local _t='~'
    run config_get_all "${CONFIG}" link
    assert_success
    assert_output "$(printf '%s\n' "${_t}/.aws" .b .c)"
}

# Records every config_each call, one line each.
_record() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"; }

@test "config_each passes line number, key, has-value and value of every entry; comments and blanks skipped" {
    _bytes "${CONFIG}" '# c\n\ntmux=host\n   \nhome\n  # indented\nfuture=a = b\nlast=x'
    run config_each "${CONFIG}" _record
    assert_success
    assert_output "$(printf '%s\n' '3|tmux|1|host' '5|home|0|' '7|future|1|a = b' '8|last|1|x')"
}

_stop_at_home() { [[ "$2" != home ]] || { echo "stop at $1"; return 3; }; }

@test "config_each stops at the first failing callback and returns its status" {
    _bytes "${CONFIG}" 'tmux=host\nhome=/x\nbox=dev\n'
    run config_each "${CONFIG}" _stop_at_home
    assert_failure 3
    assert_output "stop at 2"
}

# --- writing: in place, byte-exact -------------------------------------------

@test "config_set replaces its keys in place, drops their duplicates, appends new keys, keeps every other line" {
    _bytes "${CONFIG}" '# notes\n\nlink=~/.aws\ntmux=host\nfuture=x = y\nlink=~/.aws\ntmux=inside\nhome\n  \n# end\n'
    _bytes "${EXPECTED}" '# notes\n\nlink=~/.aws\ntmux=inside\nfuture=x = y\nlink=~/.aws\nhome=/srv/box\n  \n# end\nhome.source=user\n'
    run config_set "${CONFIG}" tmux inside home /srv/box home.source user
    assert_success
    _assert_bytes
}

@test "config_set keeps a missing final newline when it appends nothing" {
    _bytes "${CONFIG}" 'link=~/.aws\nhome=/old\nlast=x'
    _bytes "${EXPECTED}" 'link=~/.aws\nhome=/new\nlast=x'
    run config_set "${CONFIG}" home /new
    assert_success
    _assert_bytes
}

@test "config_set keeps a missing final newline on its own last line" {
    _bytes "${CONFIG}" 'link=~/.aws\nhome=/old'
    _bytes "${EXPECTED}" 'link=~/.aws\nhome=/new'
    run config_set "${CONFIG}" home /new
    assert_success
    _assert_bytes
}

@test "config_set separates an appended key from a last line without a newline, and only then" {
    _bytes "${CONFIG}" 'link=~/.aws'
    _bytes "${EXPECTED}" 'link=~/.aws\nhome=/new\n'
    run config_set "${CONFIG}" home /new
    assert_success
    _assert_bytes
}

@test "config_set keeps trailing blank lines and a whitespace-only last line" {
    _bytes "${CONFIG}" 'home=/old\nlink=.a\n\n\n'
    _bytes "${EXPECTED}" 'home=/new\nlink=.a\n\n\n'
    run config_set "${CONFIG}" home /new
    assert_success
    _assert_bytes
    _bytes "${CONFIG}" 'home=/old\nlink=.a\n  \t '
    _bytes "${EXPECTED}" 'home=/new\nlink=.a\n  \t '
    run config_set "${CONFIG}" home /new
    assert_success
    _assert_bytes
}

@test "config_set keeps CRLF lines it does not own byte-for-byte" {
    _bytes "${CONFIG}" '# note\r\nlink=~/.aws\r\nhome=/old\nfuture=x\r\n'
    _bytes "${EXPECTED}" '# note\r\nlink=~/.aws\r\nhome=/new\nfuture=x\r\nhome.source=user\n'
    run config_set "${CONFIG}" home /new home.source user
    assert_success
    _assert_bytes
}

@test "config_set keeps backslashes and spaces verbatim" {
    _bytes "${CONFIG}" 'note=a\\tb \\\\ c\nbox=dev\n'
    printf '%s\n' 'note=a\tb \\ c' 'box=dev' 'home=/srv/my \n box' >"${EXPECTED}"
    run config_set "${CONFIG}" home '/srv/my \n box'
    assert_success
    _assert_bytes
}

@test "config_set creates a missing file (and its directory) with a header" {
    run config_set "${CONFIG}" home /srv/box home.source default
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
    run config_set "${CONFIG}" tmux inside
    assert_success
    assert_equal "$(stat -c %a "${CONFIG}")" "640"
    run ls -A "$(dirname -- "${CONFIG}")"
    assert_output "config"
}

@test "config_set with an odd number of arguments is refused and writes nothing" {
    _bytes "${CONFIG}" 'tmux=host'
    cp "${CONFIG}" "${EXPECTED}"
    run config_set "${CONFIG}" tmux
    assert_failure
    _assert_bytes
}

@test "config_write_atomic replaces the file with stdin byte-for-byte and keeps its mode" {
    _bytes "${CONFIG}" 'old\n'
    chmod 0604 "${CONFIG}"
    _bytes "${EXPECTED}" 'new\n\n'
    run config_write_atomic "${CONFIG}" <"${EXPECTED}"
    assert_success
    _assert_bytes
    assert_equal "$(stat -c %a "${CONFIG}")" "604"
}

# --- concurrency ---------------------------------------------------------------

# Two writers of different keys started together, many rounds: with the
# read-modify-rename serialised, every write lands; without it one writer's
# rename would erase the other's key.
_race() {
    local _i
    for _i in $(seq 1 30); do
        config_set "${CONFIG}" "$1" "v${_i}" &
        config_set "${CONFIG}" "$2" "v${_i}" &
        wait
        [[ "$(config_get "${CONFIG}" "$1")" == "v${_i}" \
            && "$(config_get "${CONFIG}" "$2")" == "v${_i}" ]] \
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

# --- one owner: nothing else touches the state file --------------------------

# The only way to the state file is lib/config.sh. Two text-level checks
# over lib/ and script/ (lib/config.sh excluded):
#   1. no redirection or file tool is applied to a variable that holds the
#      state file path (CONFIG, _config) or to $(enter_config_path);
#   2. the functions that receive the path as an argument read it only
#      through config_* calls: their bodies hold no input redirection
#      from a variable, and no awk / grep / sed / cat / head / tail / mv / cp.
@test "no file other than lib/config.sh reads or writes the state file itself" {
    local -a _files
    mapfile -t _files < <(find "${REPO_ROOT}/lib" "${REPO_ROOT}/script" -name '*.sh' \
        ! -path "${REPO_ROOT}/lib/config.sh" | sort)
    local _io="(<|>|\\b(cat|awk|grep|sed|head|tail|mv|cp|rm|mktemp)\\b[^|;&]*)[[:space:]]*\"?[\$](\\{(CONFIG|_config)\\}|(CONFIG|_config)\\b|\\(enter_config_path\\))"
    run grep -nE "${_io}" "${_files[@]}"
    assert_failure 1
    local _fn _body
    for _fn in enter_config_get enter_config_check home_config_check home_record link_entries; do
        _body="$(awk -v f="${_fn}" '
            $0 ~ "^" f "\\(\\)" { print; if ($0 ~ /}[[:space:]]*$/) exit; on = 1; next }
            on { print }
            on && /^}/ { exit }' "${_files[@]}")"
        [[ -n "${_body}" ]] || fail "function ${_fn} not found"
        run grep -nE '(^|[^<])<[[:space:]]*"?\$|\b(awk|grep|sed|cat|head|tail|mv|cp)\b' <<<"${_body}"
        assert_failure 1
    done
}
