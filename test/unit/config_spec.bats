#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/config_spec.bats - lib/config.sh: the ONE reader/writer of the
# worktool state file (~/.config/worktool/config), issue #199 round 3.
#
# Contract under test:
#   - config_get <file> <key>: the value of the FIRST `<key>=` line (a bare
#     `<key>` line reads as empty); nothing for an absent file or key.
#   - config_set <file> <key> <value> [<key> <value> ...]: each given key
#     is set IN PLACE - its first line is replaced, any later line of the
#     same key is dropped (the writer owns that key) - and a key the file
#     does not hold yet is appended, in argument order. Every other line
#     (comments, blank lines, keys of other writers, keys of a later
#     version, their duplicates) stays byte-for-byte and in place. A new
#     file starts with one comment header. The write is atomic (temp file
#     in the same directory, then rename) and keeps the file's mode.
#   - config_write_atomic <file>: replace <file> with stdin atomically,
#     keeping an existing file's mode.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    mkdir -p "${HOME}"
    CONFIG="${HOME}/.config/worktool/config"
    # shellcheck source=../../lib/config.sh
    source "${LIB_DIR}/config.sh"
}

_write_config() {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf '%s\n' "$@" >"${CONFIG}"
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

@test "config_get reads the first occurrence; absent file or key reads as nothing" {
    run config_get "${CONFIG}" tmux
    assert_success
    assert_output ""
    _write_config '# c' 'tmux=host' 'tmux=inside' 'home' 'path=/a=b'
    run config_get "${CONFIG}" tmux
    assert_output "host"
    run config_get "${CONFIG}" path
    assert_output "/a=b"
    run config_get "${CONFIG}" home
    assert_output ""
    run config_get "${CONFIG}" box
    assert_output ""
}

@test "config_set replaces its keys in place, drops their duplicates, appends new keys, keeps every other line" {
    _write_config '# notes' '' 'link=~/.aws' 'tmux=host' 'future=x = y' \
        'link=~/.aws' 'tmux=inside' 'home' '  ' '# end'
    run config_set "${CONFIG}" tmux inside home /srv/box home.source user
    assert_success
    run cat "${CONFIG}"
    assert_output "$(printf '%s\n' '# notes' '' 'link=~/.aws' 'tmux=inside' 'future=x = y' \
        'link=~/.aws' 'home=/srv/box' '  ' '# end' 'home.source=user')"
}

@test "config_set keeps backslashes and spaces verbatim, and a last line without a newline" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'note=a\\tb \\\\ c\nbox=dev' >"${CONFIG}"
    run config_set "${CONFIG}" home '/srv/my \n box'
    assert_success
    run cat "${CONFIG}"
    assert_output "$(printf '%s\n' 'note=a\tb \\ c' 'box=dev' 'home=/srv/my \n box')"
}

@test "config_set creates a missing file (and its directory) with a header" {
    run config_set "${CONFIG}" home /srv/box home.source default
    assert_success
    run cat "${CONFIG}"
    assert_line --index 0 --regexp '^# worktool state'
    assert_line --index 1 "home=/srv/box"
    assert_line --index 2 "home.source=default"
    assert_equal "${#lines[@]}" 3
}

@test "config_set keeps the file's mode and leaves no temp file behind" {
    _write_config 'tmux=host'
    chmod 0640 "${CONFIG}"
    run config_set "${CONFIG}" tmux inside
    assert_success
    assert_equal "$(stat -c %a "${CONFIG}")" "640"
    run ls -A "$(dirname -- "${CONFIG}")"
    assert_output "config"
}

@test "config_set with an odd number of arguments is refused and writes nothing" {
    _write_config 'tmux=host'
    run config_set "${CONFIG}" tmux
    assert_failure
    assert_equal "$(cat "${CONFIG}")" "tmux=host"
}

@test "config_write_atomic replaces the file with stdin and keeps its mode" {
    _write_config 'old'
    chmod 0604 "${CONFIG}"
    run config_write_atomic "${CONFIG}" <<<"new"
    assert_success
    assert_equal "$(cat "${CONFIG}")" "new"
    assert_equal "$(stat -c %a "${CONFIG}")" "604"
}
