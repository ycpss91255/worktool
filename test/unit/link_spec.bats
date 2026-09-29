#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR  # resolve `source=` relative to this file's dir
# test/unit/link_spec.bats - lib/link.sh: link user config into the box HOME
# with symlinks (issue #199, ADR 0002 decision 3)
#
# Written test-first (RED) before lib/link.sh exists, then the library is
# implemented to pass (GREEN).
#
# Contract under test:
#   - The default list is ~/.ssh ~/.gitconfig ~/.gnupg ~/.config/gh; the
#     state file ($XDG_CONFIG_HOME/worktool/config) extends it with
#     `link=<path>` lines (HOME-relative, `~/` allowed). An entry outside
#     HOME or holding a `..` component is warned about and skipped.
#   - Each entry becomes <box home>/<path> -> $HOME/<path>, an ABSOLUTE
#     symlink (the host HOME is mounted at the same path inside the box).
#     Nothing is copied and the host file is never modified.
#   - An existing entry in the box HOME (file, directory or a foreign
#     symlink) is never overwritten: [WARN] and skip.
#   - A missing host source is skipped (no dangling link is made).
#   - Every entry is logged on stderr; stdout stays empty.
#   - The box HOME is the state file's `home=` value (leading `~/`
#     expanded), else ~/<box>-box - the default #198 records.
#   - Every path derives from HOME / XDG_CONFIG_HOME: a throwaway HOME per
#     case, the real home is never touched.

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

setup() {
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CONFIG_HOME
    mkdir -p "${HOME}"
    CONFIG="${HOME}/.config/worktool/config"
    BOX_HOME="${HOME}/dev-box"
    # shellcheck source=../../lib/log.sh
    source "${LIB_DIR}/log.sh"
    # shellcheck source=../../lib/link.sh
    source "${LIB_DIR}/link.sh"
}

# Create the four default user-config sources with known content.
_make_sources() {
    mkdir -p "${HOME}/.ssh" "${HOME}/.gnupg" "${HOME}/.config/gh"
    printf 'fake-private-key\n' >"${HOME}/.ssh/id_test"
    printf '[user]\n\tname = test\n' >"${HOME}/.gitconfig"
    printf 'keyring\n' >"${HOME}/.gnupg/pubring.kbx"
    printf 'github.com:\n    user: test\n' >"${HOME}/.config/gh/hosts.yml"
}

# Write the state file with the given lines.
_write_config() {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf '%s\n' "$@" >"${CONFIG}"
}

# A fingerprint of every host source: path, type and content.
_host_fingerprint() {
    (cd "${HOME}" && find .ssh .gitconfig .gnupg .config/gh -printf '%p %y\n' \
        -exec sh -c '[ -f "$1" ] && sha256sum "$1" || true' _ {} \; | sort)
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# --- the list ------------------------------------------------------------------

@test "the default list is .ssh .gitconfig .gnupg .config/gh" {
    run link_entries "${CONFIG}"
    assert_success
    assert_equal "${output}" "$(printf '.ssh\n.gitconfig\n.gnupg\n.config/gh')"
}

@test "link= lines in the state file extend the list, ~/ and duplicates handled" {
    _write_config 'box=dev' 'link=~/.aws' 'link=.config/nvim/' 'link=.ssh' "link=${HOME}/.netrc"
    run link_entries "${CONFIG}"
    assert_success
    assert_equal "${output}" "$(printf '.ssh\n.gitconfig\n.gnupg\n.config/gh\n.aws\n.config/nvim\n.netrc')"
}

@test "an entry outside HOME or with a .. component is warned about and skipped" {
    _write_config 'link=/etc/passwd' 'link=../escape' 'link=.config/../../x' 'link=' 'link=~'
    run --separate-stderr link_entries "${CONFIG}"
    assert_success
    assert_equal "${output}" "$(printf '.ssh\n.gitconfig\n.gnupg\n.config/gh')"
    [[ "${stderr:-}" == *"[WARN]"*"/etc/passwd"* ]] || fail "no warning for /etc/passwd: ${stderr}"
    [[ "${stderr:-}" == *"../escape"* ]] || fail "no warning for ../escape: ${stderr}"
    [[ "${stderr:-}" == *".config/../../x"* ]] || fail "no warning for .config/../../x: ${stderr}"
}

# --- the box HOME ----------------------------------------------------------------

@test "the box HOME defaults to ~/<box>-box" {
    run link_box_home dev "${CONFIG}"
    assert_success
    assert_output "${HOME}/dev-box"
    run link_box_home work "${CONFIG}"
    assert_output "${HOME}/work-box"
}

@test "the box HOME is the state file's home= value, leading ~/ expanded" {
    _write_config 'home=~/boxes/dev'
    run link_box_home dev "${CONFIG}"
    assert_output "${HOME}/boxes/dev"
    _write_config 'home=/srv/dev-home'
    run link_box_home dev "${CONFIG}"
    assert_output "/srv/dev-home"
}

# --- applying the links ---------------------------------------------------------

@test "the default list is linked into the box HOME as absolute symlinks" {
    _make_sources
    run link_apply "${BOX_HOME}" "${CONFIG}"
    assert_success
    local _rel
    for _rel in .ssh .gitconfig .gnupg .config/gh; do
        [[ -L "${BOX_HOME}/${_rel}" ]] || fail "${_rel} is not a symlink"
        assert_equal "$(readlink "${BOX_HOME}/${_rel}")" "${HOME}/${_rel}"
    done
    assert_equal "$(cat "${BOX_HOME}/.ssh/id_test")" "fake-private-key"
}

@test "linking never copies or modifies the host files" {
    _make_sources
    local _before
    _before="$(_host_fingerprint)"
    run link_apply "${BOX_HOME}" "${CONFIG}"
    assert_success
    assert_equal "$(_host_fingerprint)" "${_before}"
    # The sources are still real files / directories, not moved or replaced.
    [[ -d "${HOME}/.ssh" && ! -L "${HOME}/.ssh" ]] || fail "host .ssh changed"
    [[ -f "${HOME}/.gitconfig" && ! -L "${HOME}/.gitconfig" ]] || fail "host .gitconfig changed"
    # A write through the box side lands in the ONE host copy (no second copy).
    printf 'added\n' >>"${BOX_HOME}/.gitconfig"
    run tail -n 1 "${HOME}/.gitconfig"
    assert_output "added"
}

@test "every entry is logged on stderr and stdout stays empty" {
    _make_sources
    rm -rf "${HOME}/.gnupg"
    run --separate-stderr link_apply "${BOX_HOME}" "${CONFIG}"
    assert_success
    assert_output ""
    [[ "${stderr:-}" == *"[INFO] link: ${BOX_HOME}/.ssh -> ${HOME}/.ssh"* ]] || fail "${stderr:-}"
    [[ "${stderr:-}" == *"[INFO] link: ${BOX_HOME}/.gitconfig -> ${HOME}/.gitconfig"* ]] || fail "${stderr:-}"
    [[ "${stderr:-}" == *"[INFO] link: ${BOX_HOME}/.config/gh -> ${HOME}/.config/gh"* ]] || fail "${stderr:-}"
    [[ "${stderr:-}" == *"${HOME}/.gnupg"*"not found"* ]] || fail "missing source not logged: ${stderr}"
}

@test "an existing file in the box HOME is not overwritten: warn and skip, the rest is linked" {
    _make_sources
    mkdir -p "${BOX_HOME}"
    printf 'box-own\n' >"${BOX_HOME}/.gitconfig"
    run --separate-stderr link_apply "${BOX_HOME}" "${CONFIG}"
    assert_success
    [[ ! -L "${BOX_HOME}/.gitconfig" ]] || fail ".gitconfig was replaced by a link"
    assert_equal "$(cat "${BOX_HOME}/.gitconfig")" "box-own"
    [[ "${stderr:-}" == *"[WARN]"*"${BOX_HOME}/.gitconfig"* ]] || fail "no warning: ${stderr}"
    [[ -L "${BOX_HOME}/.ssh" ]] || fail "the other entries were not linked"
    # The host copy is untouched too.
    assert_equal "$(head -n 1 "${HOME}/.gitconfig")" "[user]"
}

@test "an existing directory in the box HOME is not replaced and gets no link inside it" {
    _make_sources
    mkdir -p "${BOX_HOME}/.ssh"
    run --separate-stderr link_apply "${BOX_HOME}" "${CONFIG}"
    assert_success
    [[ ! -L "${BOX_HOME}/.ssh" ]] || fail ".ssh was replaced"
    [[ ! -e "${BOX_HOME}/.ssh/.ssh" ]] || fail "a link was created inside the existing directory"
    [[ "${stderr:-}" == *"[WARN]"*"${BOX_HOME}/.ssh"* ]] || fail "no warning: ${stderr}"
}

@test "a foreign symlink in the box HOME (even a dangling one) is left as is" {
    _make_sources
    mkdir -p "${BOX_HOME}"
    ln -s /nonexistent/elsewhere "${BOX_HOME}/.gnupg"
    run --separate-stderr link_apply "${BOX_HOME}" "${CONFIG}"
    assert_success
    assert_equal "$(readlink "${BOX_HOME}/.gnupg")" "/nonexistent/elsewhere"
    [[ "${stderr:-}" == *"[WARN]"*"${BOX_HOME}/.gnupg"* ]] || fail "no warning: ${stderr}"
}

@test "a missing host source makes no (dangling) link and is not a failure" {
    run link_apply "${BOX_HOME}" "${CONFIG}"
    assert_success
    local _rel
    for _rel in .ssh .gitconfig .gnupg .config/gh; do
        [[ ! -e "${BOX_HOME}/${_rel}" && ! -L "${BOX_HOME}/${_rel}" ]] || fail "${_rel} was created"
    done
}

@test "an extended entry is linked, parent directories created in the box HOME" {
    _make_sources
    mkdir -p "${HOME}/.config/nvim"
    printf 'set number\n' >"${HOME}/.config/nvim/init.vim"
    _write_config 'link=~/.config/nvim'
    run link_apply "${BOX_HOME}" "${CONFIG}"
    assert_success
    assert_equal "$(readlink "${BOX_HOME}/.config/nvim")" "${HOME}/.config/nvim"
    [[ -d "${BOX_HOME}/.config" && ! -L "${BOX_HOME}/.config" ]] || fail "parent not a real dir"
}

@test "a second run is idempotent: the links stay and are reported as already linked" {
    _make_sources
    link_apply "${BOX_HOME}" "${CONFIG}" 2>/dev/null
    run --separate-stderr link_apply "${BOX_HOME}" "${CONFIG}"
    assert_success
    assert_equal "$(readlink "${BOX_HOME}/.ssh")" "${HOME}/.ssh"
    [[ "${stderr:-}" == *"already linked"* ]] || fail "${stderr:-}"
    [[ "${stderr:-}" != *"[WARN]"* ]] || fail "our own link was reported as blocked: ${stderr}"
}

# --- states (read by `just box status`) ----------------------------------------

@test "link_state reports linked, missing-source, blocked and absent" {
    _make_sources
    run link_state .ssh "${BOX_HOME}"
    assert_output "absent"
    link_apply "${BOX_HOME}" "${CONFIG}" 2>/dev/null
    run link_state .ssh "${BOX_HOME}"
    assert_output "linked"
    rm -rf "${HOME}/.gnupg" "${BOX_HOME}/.gnupg"
    run link_state .gnupg "${BOX_HOME}"
    assert_output "missing-source"
    rm "${BOX_HOME}/.gitconfig"
    printf 'box-own\n' >"${BOX_HOME}/.gitconfig"
    run link_state .gitconfig "${BOX_HOME}"
    assert_output "blocked"
}
