#!/usr/bin/env bats
# test/unit/setup_spec.bats - script/box/setup.sh: user-selectable auto-enter
# (M3, issue #21)
#
# Written test-first (RED) before the script exists, then the script is
# implemented to pass (GREEN).
#
# Contract under test:
#   - Every decision is resolved as option (user) > stored user choice >
#     default, and logged on stderr as `[INFO] <key>: <value> (<source>)`:
#     auto-enter yes|no (default yes), terminal ghostty|none (default ghostty
#     when the ghostty executable is on PATH, or a ghostty config dir exists;
#     else none), tmux inside|host (default inside), box <name> (default dev).
#   - The decisions land in ONE state file, $XDG_CONFIG_HOME/worktool/config
#     (default ~/.config/worktool/config): `<key>=<value>` plus
#     `<key>.source=default|user` per key. User choices persist across runs;
#     default keys are recomputed on every run.
#   - auto-enter yes + terminal ghostty writes ONE managed block (begin/end
#     marker lines) into $XDG_CONFIG_HOME/ghostty/config: tmux inside ->
#     `command = '<distrobox>' enter <box> -- tmux new -A -s main`; tmux host
#     -> `command = tmux new -A -s main` plus a managed block in ~/.tmux.conf
#     (`set -g default-command '"<distrobox>" enter <box>'`). Re-runs are
#     idempotent (the block is replaced in place, never duplicated); user
#     content around the block is preserved.
#   - auto-enter no removes both managed blocks and reports each removal.
#   - Every file written / removed is logged; --dry-run logs what it would do
#     and writes NOTHING (not even the state file).
#   - The script owns its CLI: --help / -h exit 0; an unknown option or an
#     invalid value is refused with `setup.sh: ... (see --help)` on stderr,
#     exit 2, before anything is touched.
#
# ISSUE #175 (the two bugs the M3 real-machine acceptance hit)
#   (1) The terminal default follows the ghostty EXECUTABLE (`command -v
#       ghostty`), not the config directory: a clean machine has
#       /usr/bin/ghostty and no ~/.config/ghostty yet, and used to be
#       resolved to `none`. The config dir stays a secondary signal, and
#       the basis of the decision is logged.
#   (2) `<distrobox>` above is the ABSOLUTE path setup.sh resolved, never
#       the bare name: a terminal started from the desktop inherits the
#       systemd user manager's PATH, which does not hold ~/.local/bin, so
#       a bare `distrobox` dies with `/bin/sh: 1: distrobox: not found`.
#   Every case here therefore installs a distrobox of its own, in a
#   directory no test image has on PATH, so the expectations do not depend
#   on what the image happens to ship.
#
# ISSUE #175 ROUND 1 (what codex blocked on)
#   (a) With nothing to resolve, the run is REFUSED (exit 1, nothing
#       written) instead of writing the bare name behind a warning - that
#       bare name IS the broken configuration the real machine hit.
#       `--distrobox <path>` serves the "configure now, install later" flow.
#   (b) Both managed bodies are shell SOURCE, so the path is written as a
#       QUOTED shell word: an install path holding a space, a `$`, a
#       backtick or a quote must reach the one binary and must not run
#       anything else.
#
# Every path comes from HOME / XDG_CONFIG_HOME, so each case runs against a
# throwaway HOME under BATS_TEST_TMPDIR: the real home is never read or
# written.

load "${BATS_TEST_DIRNAME}/../helper/common"

# `run -127` (a control case asserting `command not found`) is a flagged
# run, which bats only accepts once the minimum version is declared.
bats_require_minimum_version 1.5.0

setup() {
    SETUP="${REPO_ROOT}/script/box/setup.sh"
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    unset XDG_CONFIG_HOME
    mkdir -p "${HOME}"
    CONFIG="${HOME}/.config/worktool/config"
    GHOSTTY="${HOME}/.config/ghostty/config"
    TMUX_CONF="${HOME}/.tmux.conf"
    BEGIN="# BEGIN worktool managed block (just box setup; do not edit)"
    END="# END worktool managed block"

    # Issue #175 (2): the distrobox every case resolves. It lives under the
    # case's own tmpdir - a directory no test image has on PATH - so the
    # expected managed command is the same in every image.
    DBX_DIR="${BATS_TEST_TMPDIR}/local/bin"
    DISTROBOX="${DBX_DIR}/distrobox"
    _fake_distrobox "${DISTROBOX}"
    PATH="${DBX_DIR}:${PATH}"
    export PATH

    # Issue #175 round 1: both bodies are shell source, so the path is
    # QUOTED. ghostty runs its `command` through /bin/sh -c, hence a
    # single-quoted word; the tmux body nests that shell command inside a
    # tmux single-quoted value, so the inner word is double-quoted instead.
    CMD_INSIDE="command = '${DISTROBOX}' enter dev -- tmux new -A -s main"
    CMD_HOST="command = tmux new -A -s main"
    TMUX_BODY="set -g default-command '\"${DISTROBOX}\" enter dev'"
}

# Install an executable stand-in for distrobox at $1. setup.sh only
# RESOLVES and writes its path, so the stand-in never has to do anything;
# it records its arguments so a case that runs the managed command can
# prove which binary answered.
_fake_distrobox() {
    mkdir -p "$(dirname -- "$1")"
    # The log path comes from $0 at RUN time, never interpolated into the
    # script: a case installs this under a directory whose name holds `$`,
    # a backtick or a quote, and a path baked into the body would be
    # re-evaluated by the shell that runs it (issue #175 round 1).
    cat >"$1" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$0.log"
EOF
    chmod +x "$1"
}

# Number of managed-block begin markers in file $1 (0 when absent).
_block_count() {
    [[ -f "$1" ]] || { printf '0\n'; return 0; }
    grep -cxF "${BEGIN}" "$1" || true
}

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}

# --- defaults + logging ------------------------------------------------------

@test "defaults (no ghostty dir): yes / none / inside / dev, each logged as (default), state file written with sources" {
    run "${SETUP}"
    assert_success
    assert_line "[INFO] auto-enter: yes (default)"
    assert_line "[INFO] terminal: none (default)"
    assert_line "[INFO] tmux: inside (default)"
    assert_line "[INFO] box: dev (default)"
    assert_line "[INFO] wrote: ${CONFIG}"
    run cat "${CONFIG}"
    assert_line "auto-enter=yes"
    assert_line "auto-enter.source=default"
    assert_line "terminal=none"
    assert_line "terminal.source=default"
    assert_line "tmux=inside"
    assert_line "tmux.source=default"
    assert_line "box=dev"
    assert_line "box.source=default"
    assert [ ! -e "${GHOSTTY}" ]
    assert [ ! -e "${TMUX_CONF}" ]
}

@test "#198: setup keeps the box home lines assemble recorded in the state file" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'tmux=host\ntmux.source=user\nhome=/srv/my box\nhome.source=user\n' >"${CONFIG}"
    run "${SETUP}" --auto-enter no
    assert_success
    run cat "${CONFIG}"
    assert_line "tmux=host"
    assert_line "home=/srv/my box"
    assert_line "home.source=user"
    assert_equal "$(grep -c '^home=' "${CONFIG}")" 1
}

# --- #199 r3: setup owns only its own keys in the shared state file --------
# The state file has several writers (setup: the four decisions; assemble:
# home / home.source; the user: link= lines). setup must update its own
# keys in place and keep every other line byte-for-byte: comments, blank
# lines, link= entries (duplicates too), the box home, keys a later
# version may add.

# The foreign lines of state file $1: every line that is not one of
# setup's own keys (<decision>, <decision>.source, bare or with a value).
_foreign() {
    grep -vE '^(auto-enter|terminal|tmux|box)(\.source)?(=|$)' "$1" || true
}

# A state file mixing setup's own keys (interleaved, one duplicated) with
# every kind of foreign line.
_write_mixed_config() {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf '%s\n' \
        '# my own notes about worktool' \
        '' \
        'link=~/.aws' \
        'tmux=host' \
        'tmux.source=user' \
        'link=.config/foo' \
        'link=~/.aws' \
        'future-key=some value = with = inside' \
        'future-key.source=user' \
        'box=dev' \
        'box=dev' \
        'home=/srv/my box' \
        'home.source=user' \
        '   ' \
        '# trailing comment' >"${CONFIG}"
}

@test "#199 r3: every setup run keeps every foreign line byte-for-byte and updates its own keys once" {
    local _args _before
    local -a _opts
    for _args in '' '--terminal none --tmux inside --box work' '--auto-enter no'; do
        read -r -a _opts <<<"${_args}"
        _write_mixed_config
        _before="$(_foreign "${CONFIG}")"
        run "${SETUP}" "${_opts[@]}"
        assert_success
        assert_equal "$(_foreign "${CONFIG}")" "${_before}"
        run grep -cE '^(auto-enter|terminal|tmux|box)(\.source)?=' "${CONFIG}"
        assert_output "8"
    done
    # The last run (--auto-enter no) stored its choice; tmux and box kept
    # their stored values.
    run cat "${CONFIG}"
    assert_line "auto-enter=no"
    assert_line "auto-enter.source=user"
    assert_line "tmux=host"
    assert_line "box=dev"
    assert_line "link=~/.aws"
}

@test "#199 r3: a user link= line survives just box setup (the lost-entry regression)" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'link=~/.aws\n' >"${CONFIG}"
    run "${SETUP}"
    assert_success
    run grep -x 'link=~/.aws' "${CONFIG}"
    assert_success
}

@test "#199 r3: setup keeps the state file's mode" {
    _write_mixed_config
    chmod 0640 "${CONFIG}"
    run "${SETUP}"
    assert_success
    assert_equal "$(stat -c %a "${CONFIG}")" "640"
}

@test "terminal none with auto-enter yes says no terminal profile is managed and names the manual command" {
    run "${SETUP}"
    assert_success
    assert_line "[INFO] terminal profile: none (nothing written; enter by hand: distrobox enter dev)"
}

@test "terminal defaults to ghostty when ~/.config/ghostty exists: block written there, logged as (default)" {
    mkdir -p "${HOME}/.config/ghostty"
    run "${SETUP}"
    assert_success
    assert_line "[INFO] terminal: ghostty (default)"
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_INSIDE})"
    run cat "${GHOSTTY}"
    assert_line --index 0 "${BEGIN}"
    assert_line --index 1 "${CMD_INSIDE}"
    assert_line --index 2 "${END}"
    assert_equal "${#lines[@]}" 3
    assert [ ! -e "${TMUX_CONF}" ]
}

@test "XDG_CONFIG_HOME relocates both the state file and the ghostty config" {
    local _xdg="${BATS_TEST_TMPDIR}/xdg"
    mkdir -p "${_xdg}/ghostty"
    XDG_CONFIG_HOME="${_xdg}" run "${SETUP}"
    assert_success
    assert_line "[INFO] terminal: ghostty (default)"
    assert_line "[INFO] wrote: ${_xdg}/worktool/config"
    assert_line "[INFO] wrote: ${_xdg}/ghostty/config (managed block: ${CMD_INSIDE})"
    assert [ -f "${_xdg}/worktool/config" ]
    assert [ ! -e "${CONFIG}" ]
    assert [ ! -e "${GHOSTTY}" ]
}

# --- user overrides ----------------------------------------------------------

@test "user overrides are logged as (user) and stored with source=user" {
    run "${SETUP}" --auto-enter yes --terminal ghostty --tmux host --box work
    assert_success
    assert_line "[INFO] auto-enter: yes (user)"
    assert_line "[INFO] terminal: ghostty (user)"
    assert_line "[INFO] tmux: host (user)"
    assert_line "[INFO] box: work (user)"
    run cat "${CONFIG}"
    assert_line "auto-enter.source=user"
    assert_line "terminal=ghostty"
    assert_line "terminal.source=user"
    assert_line "tmux=host"
    assert_line "tmux.source=user"
    assert_line "box=work"
    assert_line "box.source=user"
}

@test "--key=value spelling is accepted for every value option" {
    run "${SETUP}" --auto-enter=yes --terminal=ghostty --tmux=host --box=work
    assert_success
    assert_line "[INFO] terminal: ghostty (user)"
    assert_line "[INFO] tmux: host (user)"
    assert_line "[INFO] box: work (user)"
}

@test "a stored user choice persists across runs; a default key is recomputed" {
    run "${SETUP}" --box work
    assert_success
    assert_line "[INFO] terminal: none (default)"
    # Second run, no option: box stays the user's; terminal is re-detected.
    mkdir -p "${HOME}/.config/ghostty"
    run "${SETUP}"
    assert_success
    assert_line "[INFO] box: work (user)"
    assert_line "[INFO] terminal: ghostty (default)"
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: command = '${DISTROBOX}' enter work -- tmux new -A -s main)"
}

# --- ghostty block: exactly once, idempotent, user content preserved ---------

@test "the ghostty block is written exactly once and a re-run is idempotent (unchanged)" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n' >"${GHOSTTY}"
    run "${SETUP}" --terminal ghostty
    assert_success
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_INSIDE})"
    local _first
    _first="$(cat "${GHOSTTY}")"
    assert_equal "$(_block_count "${GHOSTTY}")" "1"

    run "${SETUP}" --terminal ghostty
    assert_success
    assert_line "[INFO] unchanged: ${GHOSTTY} (managed block already up to date)"
    assert_equal "$(_block_count "${GHOSTTY}")" "1"
    assert_equal "$(cat "${GHOSTTY}")" "${_first}"
    run cat "${GHOSTTY}"
    assert_line --index 0 "theme = dark"
    assert_line --index 1 "${BEGIN}"
    assert_line --index 2 "${CMD_INSIDE}"
    assert_line --index 3 "${END}"
    assert_equal "${#lines[@]}" 4
}

@test "a changed decision replaces the block in place: user lines before and after it survive" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n%s\n%s\n%s\nfont-size = 12\n' \
        "${BEGIN}" "${CMD_INSIDE}" "${END}" >"${GHOSTTY}"
    run "${SETUP}" --terminal ghostty --tmux host
    assert_success
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_HOST})"
    assert_equal "$(_block_count "${GHOSTTY}")" "1"
    run cat "${GHOSTTY}"
    assert_line --index 0 "theme = dark"
    assert_line --index 1 "${BEGIN}"
    assert_line --index 2 "${CMD_HOST}"
    assert_line --index 3 "${END}"
    assert_line --index 4 "font-size = 12"
    assert_equal "${#lines[@]}" 5
    refute_line "${CMD_INSIDE}"
}

# --- tmux host variant -------------------------------------------------------

@test "--tmux host: ghostty runs tmux on the host and ~/.tmux.conf gets the default-command block" {
    run "${SETUP}" --terminal ghostty --tmux host
    assert_success
    assert_line "[INFO] tmux: host (user)"
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_HOST})"
    assert_line "[INFO] wrote: ${TMUX_CONF} (managed block: ${TMUX_BODY})"
    run cat "${TMUX_CONF}"
    assert_line --index 0 "${BEGIN}"
    assert_line --index 1 "${TMUX_BODY}"
    assert_line --index 2 "${END}"
    assert_equal "${#lines[@]}" 3
}

@test "switching back to --tmux inside removes the ~/.tmux.conf block and reports it" {
    run "${SETUP}" --terminal ghostty --tmux host
    assert_success
    run "${SETUP}" --tmux inside
    assert_success
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_INSIDE})"
    assert_line "[INFO] removed: ${TMUX_CONF} (managed block: ${TMUX_BODY})"
    assert_equal "$(_block_count "${TMUX_CONF}")" "0"
}

# --- auto-enter no: restore the host shell -----------------------------------

@test "--auto-enter no removes both managed blocks, reports each, keeps user content" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n' >"${GHOSTTY}"
    printf 'set -g mouse on\n' >"${TMUX_CONF}"
    run "${SETUP}" --terminal ghostty --tmux host
    assert_success
    assert_equal "$(_block_count "${GHOSTTY}")" "1"
    assert_equal "$(_block_count "${TMUX_CONF}")" "1"

    run "${SETUP}" --auto-enter no
    assert_success
    assert_line "[INFO] auto-enter: no (user)"
    assert_line "[INFO] removed: ${GHOSTTY} (managed block: ${CMD_HOST})"
    assert_line "[INFO] removed: ${TMUX_CONF} (managed block: ${TMUX_BODY})"
    assert_equal "$(_block_count "${GHOSTTY}")" "0"
    assert_equal "$(_block_count "${TMUX_CONF}")" "0"
    assert_equal "$(cat "${GHOSTTY}")" "theme = dark"
    assert_equal "$(cat "${TMUX_CONF}")" "set -g mouse on"
    run cat "${CONFIG}"
    assert_line "auto-enter=no"
    assert_line "auto-enter.source=user"
}

@test "--auto-enter no with nothing managed says so for both files" {
    run "${SETUP}" --auto-enter no
    assert_success
    assert_line "[INFO] nothing to remove: ${GHOSTTY} (no managed block)"
    assert_line "[INFO] nothing to remove: ${TMUX_CONF} (no managed block)"
    assert [ ! -e "${GHOSTTY}" ]
    assert [ ! -e "${TMUX_CONF}" ]
}

# --- dry-run -----------------------------------------------------------------

@test "--dry-run logs every decision and what it would write, and writes nothing" {
    mkdir -p "${HOME}/.config/ghostty"
    run "${SETUP}" --dry-run --tmux host
    assert_success
    assert_line "[INFO] auto-enter: yes (default)"
    assert_line "[INFO] terminal: ghostty (default)"
    assert_line "[INFO] tmux: host (user)"
    assert_line "[INFO] dry-run: would write ${CONFIG}"
    assert_line "[INFO] dry-run: would write ${GHOSTTY} (managed block: ${CMD_HOST})"
    assert_line "[INFO] dry-run: would write ${TMUX_CONF} (managed block: ${TMUX_BODY})"
    assert [ ! -e "${CONFIG}" ]
    assert [ ! -e "${GHOSTTY}" ]
    assert [ ! -e "${TMUX_CONF}" ]
}

@test "--dry-run --auto-enter no reports what it would remove and removes nothing" {
    run "${SETUP}" --terminal ghostty
    assert_success
    run "${SETUP}" --dry-run --auto-enter no
    assert_success
    assert_line "[INFO] dry-run: would remove managed block from ${GHOSTTY}"
    assert_equal "$(_block_count "${GHOSTTY}")" "1"
    run cat "${CONFIG}"
    assert_line "auto-enter=yes"
}

# --- the script owns its CLI -------------------------------------------------

@test "--help exits 0, names every option, and touches nothing" {
    run "${SETUP}" --help
    assert_success
    assert_output --partial "--auto-enter"
    assert_output --partial "--terminal"
    assert_output --partial "--tmux"
    assert_output --partial "--box"
    assert_output --partial "--dry-run"
    assert_output --partial "--help"
    assert [ ! -e "${CONFIG}" ]
}

@test "-h is the same as --help" {
    run "${SETUP}" --help
    local _long="${output}"
    run "${SETUP}" -h
    assert_success
    assert_output "${_long}"
}

@test "an unknown option exits 2 with the documented message on stderr, nothing on stdout, nothing written" {
    local _out="${BATS_TEST_TMPDIR}/out" _err="${BATS_TEST_TMPDIR}/err"
    run bash -c '"$1" --bogus >"$2" 2>"$3"' _ "${SETUP}" "${_out}" "${_err}"
    assert_failure 2
    run cat "${_out}"
    assert_output ""
    run cat "${_err}"
    assert_output "setup.sh: unknown option '--bogus' (see --help)"
    assert [ ! -e "${CONFIG}" ]
}

@test "an unknown option is refused even when combined with --help: exit 2 and no usage" {
    run "${SETUP}" --help --bogus
    assert_failure 2
    assert_output "setup.sh: unknown option '--bogus' (see --help)"
    refute_output --partial "Usage:"
}

@test "an invalid value is refused with the expected choices, exit 2, nothing written" {
    run "${SETUP}" --auto-enter maybe
    assert_failure 2
    assert_output "setup.sh: invalid value 'maybe' for --auto-enter (expected yes|no) (see --help)"
    run "${SETUP}" --terminal kitty
    assert_failure 2
    assert_output "setup.sh: invalid value 'kitty' for --terminal (expected ghostty|none) (see --help)"
    run "${SETUP}" --tmux outside
    assert_failure 2
    assert_output "setup.sh: invalid value 'outside' for --tmux (expected inside|host) (see --help)"
    run "${SETUP}" --box 'bad name'
    assert_failure 2
    assert_output "setup.sh: invalid value 'bad name' for --box (expected a container name: [A-Za-z0-9][A-Za-z0-9_.-]*) (see --help)"
    assert [ ! -e "${CONFIG}" ]
}

@test "a value option without its value is refused, exit 2" {
    run "${SETUP}" --box
    assert_failure 2
    assert_output "setup.sh: --box requires a value (see --help)"
    assert [ ! -e "${CONFIG}" ]
}

@test "a corrupt stored value is refused with a clear error, exit 1, nothing rewritten" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'tmux=sideways\ntmux.source=user\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for tmux (expected inside|host)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'tmux=sideways\ntmux.source=user')"
}

# --- #161 (2): every stored value is validated, whatever its source ----------

@test "a corrupt stored value whose source is default is refused too: exit 1, no file changed" {
    mkdir -p "$(dirname -- "${CONFIG}")" "${HOME}/.config/ghostty"
    printf 'tmux=sideways\ntmux.source=default\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for tmux (expected inside|host)"
    refute_line --partial "wrote:"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'tmux=sideways\ntmux.source=default')"
    assert [ ! -e "${GHOSTTY}" ]
}

@test "a corrupt stored value is refused even when the option overrides that key" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'box=bad name\nbox.source=default\n' >"${CONFIG}"
    run "${SETUP}" --box work
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'bad name' for box (expected a container name: [A-Za-z0-9][A-Za-z0-9_.-]*)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'box=bad name\nbox.source=default')"
}

@test "a corrupt stored source is refused: exit 1, nothing rewritten" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'tmux=host\ntmux.source=guess\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'guess' for tmux.source (expected default|user)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'tmux=host\ntmux.source=guess')"
}

# A key that IS present with an empty value is a stored value like any other:
# it is refused, never mistaken for an absent key (absent = default applies).
@test "an empty stored value is refused: a present key is validated even when its value is empty" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'tmux=\ntmux.source=user\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value '' for tmux (expected inside|host)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'tmux=\ntmux.source=user')"
    printf 'box=\nbox.source=user\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value '' for box (expected a container name: [A-Za-z0-9][A-Za-z0-9_.-]*)"
    printf 'tmux=host\ntmux.source=\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value '' for tmux.source (expected default|user)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'tmux=host\ntmux.source=')"
}

# Every LINE is validated, not just the first line per key: a corrupt
# duplicate hiding behind a valid first occurrence is refused too.
@test "a corrupt duplicate key is refused even when its first occurrence is valid" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'tmux=host\ntmux=sideways\ntmux.source=user\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for tmux (expected inside|host)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'tmux=host\ntmux=sideways\ntmux.source=user')"
    printf 'tmux=host\ntmux.source=user\ntmux.source=guess\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'guess' for tmux.source (expected default|user)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'tmux=host\ntmux.source=user\ntmux.source=guess')"
}

# --- #161 (1): terminal none never writes a terminal profile ------------------

@test "--terminal none --tmux host stores the decision but writes no ~/.tmux.conf" {
    run "${SETUP}" --terminal none --tmux host
    assert_success
    assert_line "[INFO] terminal: none (user)"
    assert_line "[INFO] tmux: host (user)"
    assert_line "[INFO] terminal profile: none (nothing written; enter by hand: distrobox enter dev)"
    refute_line --partial "wrote: ${TMUX_CONF}"
    assert [ ! -e "${TMUX_CONF}" ]
    assert [ ! -e "${GHOSTTY}" ]
    run cat "${CONFIG}"
    assert_line "tmux=host"
    assert_line "tmux.source=user"
}

@test "switching to --terminal none removes the ~/.tmux.conf block an earlier ghostty+host run left" {
    run "${SETUP}" --terminal ghostty --tmux host
    assert_success
    assert_equal "$(_block_count "${TMUX_CONF}")" "1"
    run "${SETUP}" --terminal none
    assert_success
    assert_line "[INFO] tmux: host (user)"
    assert_line "[INFO] removed: ${TMUX_CONF} (managed block: ${TMUX_BODY})"
    assert_line "[INFO] removed: ${GHOSTTY} (managed block: ${CMD_HOST})"
    assert_equal "$(_block_count "${TMUX_CONF}")" "0"
    assert_equal "$(_block_count "${GHOSTTY}")" "0"
}

# --- #161 (3): exactly one managed block per file ----------------------------

@test "a file that already holds two managed blocks is collapsed to exactly one, in place of the first" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n%s\n%s\n%s\nfont-size = 12\n%s\n%s\n%s\ntail = 1\n' \
        "${BEGIN}" "${CMD_INSIDE}" "${END}" "${BEGIN}" "${CMD_INSIDE}" "${END}" >"${GHOSTTY}"
    assert_equal "$(_block_count "${GHOSTTY}")" "2"
    run "${SETUP}" --terminal ghostty
    assert_success
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_INSIDE})"
    refute_line --partial "unchanged:"
    assert_equal "$(_block_count "${GHOSTTY}")" "1"
    run cat "${GHOSTTY}"
    assert_line --index 0 "theme = dark"
    assert_line --index 1 "${BEGIN}"
    assert_line --index 2 "${CMD_INSIDE}"
    assert_line --index 3 "${END}"
    assert_line --index 4 "font-size = 12"
    assert_line --index 5 "tail = 1"
    assert_equal "${#lines[@]}" 6
}

@test "--auto-enter no removes every managed block a file holds" {
    printf '%s\n%s\n%s\nset -g mouse on\n%s\n%s\n%s\n' \
        "${BEGIN}" "${TMUX_BODY}" "${END}" "${BEGIN}" "${TMUX_BODY}" "${END}" >"${TMUX_CONF}"
    run "${SETUP}" --auto-enter no
    assert_success
    assert_line "[INFO] removed: ${TMUX_CONF} (managed block: ${TMUX_BODY})"
    assert_equal "$(_block_count "${TMUX_CONF}")" "0"
    assert_equal "$(cat "${TMUX_CONF}")" "set -g mouse on"
}

# --- #161 (non-blocking): a rewrite keeps the file mode ----------------------

# --- #175 (1): the terminal default follows the ghostty EXECUTABLE -----------
#
# The M3 real-machine acceptance failed here: /usr/bin/ghostty was installed
# and ~/.config/ghostty did not exist yet, so `just box setup` chose `none`
# and wrote nothing at all. The executable is the primary signal now, and
# every case below also asserts the line that says WHY.

@test "#175: terminal defaults to ghostty when the executable is on PATH even though no config dir exists" {
    local _bin="${BATS_TEST_TMPDIR}/ghostty-bin"
    mkdir -p "${_bin}"
    printf '#!/bin/sh\nexit 0\n' >"${_bin}/ghostty"
    chmod +x "${_bin}/ghostty"
    assert [ ! -d "${HOME}/.config/ghostty" ]
    PATH="${_bin}:${PATH}" run "${SETUP}"
    assert_success
    assert_line "[INFO] terminal: ghostty (default)"
    assert_line "[INFO] terminal detected: ghostty (ghostty executable ${_bin}/ghostty)"
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_INSIDE})"
}

@test "#175: the config dir alone still selects ghostty when no executable is on PATH, and the log says so" {
    mkdir -p "${HOME}/.config/ghostty"
    run "${SETUP}"
    assert_success
    assert_line "[INFO] terminal: ghostty (default)"
    assert_line "[INFO] terminal detected: ghostty (no ghostty executable on PATH; config dir ${HOME}/.config/ghostty)"
}

@test "#175: terminal is none only when there is neither an executable nor a config dir, and the log names both" {
    run "${SETUP}"
    assert_success
    assert_line "[INFO] terminal: none (default)"
    assert_line "[INFO] terminal detected: none (no ghostty executable on PATH and no ghostty config dir)"
}

@test "#175: a user-forced --terminal prints no detection line (detection is the default's basis only)" {
    run "${SETUP}" --terminal none
    assert_success
    assert_line "[INFO] terminal: none (user)"
    refute_line --partial "terminal detected:"
}

# --- #175 (2): the managed command names an ABSOLUTE distrobox ---------------
#
# A terminal started from the desktop inherits the systemd user manager's
# PATH, which does not hold ~/.local/bin; the bare name died there with
# `/bin/sh: 1: distrobox: not found`.

@test "#175: the ghostty managed command names the absolute path of the resolved distrobox, never the bare name" {
    mkdir -p "${HOME}/.config/ghostty"
    run "${SETUP}"
    assert_success
    assert_line "[INFO] distrobox: ${DISTROBOX} (absolute path written into the managed command)"
    run cat "${GHOSTTY}"
    assert_line "command = '${DISTROBOX}' enter dev -- tmux new -A -s main"
    refute_line "command = distrobox enter dev -- tmux new -A -s main"
}

@test "#175: --tmux host names the absolute distrobox path in the ~/.tmux.conf default-command too" {
    run "${SETUP}" --terminal ghostty --tmux host
    assert_success
    assert_line "[INFO] distrobox: ${DISTROBOX} (absolute path written into the managed command)"
    run cat "${TMUX_CONF}"
    assert_line "set -g default-command '\"${DISTROBOX}\" enter dev'"
    refute_line 'set -g default-command "distrobox enter dev"'
}

# A distrobox reached through a symlink keeps the SYMLINK path: that is the
# name the user (or their package manager) installed, and an upgrade
# replaces the target behind it. Upstream's own dispatcher realpath()s $0
# before locating its siblings, so being invoked through the link is safe.
@test "#175: a distrobox reached through a symlink keeps the symlink path, not the target" {
    local _real="${BATS_TEST_TMPDIR}/opt/distrobox-1.8.2.5/distrobox"
    local _link_dir="${BATS_TEST_TMPDIR}/link/bin"
    mkdir -p "$(dirname -- "${_real}")" "${_link_dir}"
    printf '#!/bin/sh\nexit 0\n' >"${_real}"
    chmod +x "${_real}"
    ln -s "${_real}" "${_link_dir}/distrobox"
    PATH="${_link_dir}:${PATH}" run "${SETUP}" --terminal ghostty
    assert_success
    assert_line "[INFO] distrobox: ${_link_dir}/distrobox (absolute path written into the managed command)"
    run cat "${GHOSTTY}"
    assert_line "command = '${_link_dir}/distrobox' enter dev -- tmux new -A -s main"
    refute_line --partial "${_real}"
}

# --- #175 round 1 (a): an unresolvable distrobox REFUSES the run -------------
#
# Writing the bare name and warning was the first attempt, and it handed the
# user exactly the configuration the real machine failed on: a window that
# opens and closes. setup knows at that moment that the command cannot work,
# so it refuses instead of writing one - and names the way out.

@test "#175r1: with no distrobox on PATH the run is refused, nothing is written, and the error names the way out" {
    mkdir -p "${HOME}/.config/ghostty"
    PATH="/usr/bin:/bin" run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] distrobox: not found on PATH - the managed command must name an absolute path a terminal launched from the desktop can run (install distrobox, or pass --distrobox <path>); nothing was written"
    refute_line --partial "wrote:"
    assert [ ! -e "${CONFIG}" ]
    assert [ ! -e "${GHOSTTY}" ]
    assert [ ! -e "${TMUX_CONF}" ]
}

@test "#175r1: --dry-run is refused the same way (it reports what would happen, and this would fail)" {
    mkdir -p "${HOME}/.config/ghostty"
    PATH="/usr/bin:/bin" run "${SETUP}" --dry-run
    assert_failure 1
    assert_line --partial "[ERROR] distrobox: not found on PATH"
    assert [ ! -e "${CONFIG}" ]
}

# The "configure now, install later" flow issue #175 worried about: it is
# served by naming the path, not by writing a command known to be broken.
@test "#175r1: --distrobox <path> supplies the program when PATH cannot" {
    mkdir -p "${HOME}/.config/ghostty"
    PATH="/usr/bin:/bin" run "${SETUP}" --distrobox "${DISTROBOX}"
    assert_success
    assert_line "[INFO] distrobox: ${DISTROBOX} (--distrobox; absolute path written into the managed command)"
    run cat "${GHOSTTY}"
    assert_line "${CMD_INSIDE}"
}

@test "#175r1: --distrobox refuses a relative path, a missing file and a non-executable file, exit 2, nothing written" {
    local _rel="local/bin/distrobox" _missing="${BATS_TEST_TMPDIR}/gone/distrobox"
    local _plain="${BATS_TEST_TMPDIR}/plain/distrobox"
    mkdir -p "$(dirname -- "${_plain}")"
    printf '#!/bin/sh\n' >"${_plain}"
    chmod 0644 "${_plain}"
    run "${SETUP}" --distrobox "${_rel}"
    assert_failure 2
    assert_output "setup.sh: invalid value '${_rel}' for --distrobox (expected an absolute path to an executable file) (see --help)"
    run "${SETUP}" --distrobox "${_missing}"
    assert_failure 2
    assert_output "setup.sh: invalid value '${_missing}' for --distrobox (expected an absolute path to an executable file) (see --help)"
    run "${SETUP}" --distrobox "${_plain}"
    assert_failure 2
    assert_output "setup.sh: invalid value '${_plain}' for --distrobox (expected an absolute path to an executable file) (see --help)"
    run "${SETUP}" --distrobox
    assert_failure 2
    assert_output "setup.sh: --distrobox requires a value (see --help)"
    assert [ ! -e "${CONFIG}" ]
}

# The paths that never name a distrobox must stay usable on a machine that
# has none: the refusal is about the managed command, not about setup.
@test "#175r1: --terminal none and --auto-enter no still work with no distrobox anywhere" {
    PATH="/usr/bin:/bin" run "${SETUP}" --terminal none
    assert_success
    assert_line "[INFO] terminal profile: none (nothing written; enter by hand: distrobox enter dev)"
    refute_line --partial "[ERROR]"
    PATH="/usr/bin:/bin" run "${SETUP}" --auto-enter no
    assert_success
    refute_line --partial "[ERROR]"
}

# --- #175 round 1 (b): the path is SHELL-QUOTED in both bodies ---------------
#
# Both managed bodies are shell source, not argv: ghostty runs a `command`
# without a `direct:` prefix through `/bin/sh -c`, and tmux runs
# `default-command` the same way. An install path holding a space, a `$`, a
# backtick or a quote would otherwise be split into words or change the
# meaning of the command outright.

# Install a fake distrobox under a directory NAMED $1 and run setup against
# it. Asserts the ghostty body quotes the path as one POSIX shell word,
# that `/bin/sh -c` on that body really runs THAT binary with the expected
# arguments, and that nothing else ran.
_assert_ghostty_quoting() {
    local _dir="${BATS_TEST_TMPDIR}/q/$1" _dbx _cmd
    mkdir -p "${_dir}" "${HOME}/.config/ghostty"
    _dbx="${_dir}/distrobox"
    _fake_distrobox "${_dbx}"
    run "${SETUP}" --distrobox "${_dbx}"
    assert_success
    _cmd="$(sed -n 's/^command = //p' "${GHOSTTY}")"
    assert_equal "${_cmd}" "$(_squote "${_dbx}") enter dev -- tmux new -A -s main"
    run env -i PATH=/usr/bin:/bin /bin/sh -c "${_cmd}"
    assert_success
    run cat "${_dbx}.log"
    assert_line "enter dev -- tmux new -A -s main"
}

# The expected POSIX single-quoted form of $1 (the test's own encoder, so a
# bug in the delivered one cannot define its own expectation).
_squote() {
    local _s="$1"
    _s="${_s//\'/\'\\\'\'}"
    printf "'%s'\n" "${_s}"
}

@test "#175r1: a distrobox path containing SPACES is quoted and still runs as one word" {
    _assert_ghostty_quoting 'dir with spaces'
}

@test "#175r1: a distrobox path containing \$ and backticks is quoted, and the substitutions never run" {
    local _sentinel_a="${BATS_TEST_TMPDIR}/pwned-dollar" _sentinel_b="${BATS_TEST_TMPDIR}/pwned-backtick"
    _assert_ghostty_quoting "d \$(touch ${_sentinel_a}) \`touch ${_sentinel_b}\` \${HOME}"
    assert [ ! -e "${_sentinel_a}" ]
    assert [ ! -e "${_sentinel_b}" ]
}

@test "#175r1: a distrobox path containing DOUBLE QUOTES is quoted and still runs" {
    _assert_ghostty_quoting 'dir "quoted" name'
}

@test "#175r1: the ~/.tmux.conf default-command quotes the path for the shell inside tmux's own quoting" {
    local _sentinel="${BATS_TEST_TMPDIR}/pwned-tmux"
    local _dir="${BATS_TEST_TMPDIR}/qt/d \$(touch ${_sentinel}) \"q\"" _dbx _inner
    mkdir -p "${_dir}"
    _dbx="${_dir}/distrobox"
    _fake_distrobox "${_dbx}"
    run "${SETUP}" --terminal ghostty --distrobox "${_dbx}" --tmux host
    assert_success
    # tmux owns the outer single quotes (a tmux single-quoted value is fully
    # literal: no escape, no expansion), the shell owns the inner word.
    run cat "${TMUX_CONF}"
    assert_line "set -g default-command '$(_dquote "${_dbx}") enter dev'"
    # The shell half really runs that binary, and runs nothing else.
    _inner="$(sed -n "s/^set -g default-command '\(.*\)'\$/\1/p" "${TMUX_CONF}")"
    run env -i PATH=/usr/bin:/bin /bin/sh -c "${_inner}"
    assert_success
    run cat "${_dbx}.log"
    assert_line "enter dev"
    assert [ ! -e "${_sentinel}" ]
}

# The expected POSIX double-quoted form of $1 (the test's own encoder).
_dquote() {
    local _s="$1"
    _s="${_s//\\/\\\\}"
    _s="${_s//\`/\\\`}"
    _s="${_s//\$/\\\$}"
    _s="${_s//\"/\\\"}"
    printf '"%s"\n' "${_s}"
}

# A tmux single-quoted value has no escape at all, so a path holding a
# single quote cannot be encoded in the ~/.tmux.conf block. That is refused
# rather than written half-broken; the ghostty-only shape still accepts it.
@test "#175r1: --tmux host refuses a distrobox path holding a single quote instead of writing a broken tmux.conf" {
    local _dir="${BATS_TEST_TMPDIR}/qq/it's here" _dbx
    mkdir -p "${_dir}"
    _dbx="${_dir}/distrobox"
    _fake_distrobox "${_dbx}"
    run "${SETUP}" --terminal ghostty --distrobox "${_dbx}" --tmux host
    assert_failure 1
    assert_line "[ERROR] distrobox: ${_dbx} holds a single quote, which cannot be encoded safely in the ~/.tmux.conf managed block (use --tmux inside, or install distrobox at a path without one); nothing was written"
    assert [ ! -e "${TMUX_CONF}" ]
    assert [ ! -e "${CONFIG}" ]
}

@test "#175r1: --tmux inside accepts a single quote in the path (the ghostty body can encode it)" {
    _assert_ghostty_quoting "it's here"
}

# --- #175 round 2: a path holding a NEWLINE cannot go into either file ------
#
# `enter_sh_squote` makes a valid shell word out of anything, but BOTH
# managed files are LINE-BASED: a newline in the path splits the managed
# body across two lines, and ghostty then rejects the whole config
# (`unknown field`) - while setup had already written it and exited 0.
# That is the same "known-broken partial write" the bare-name fallback was.

# Install a fake distrobox under a directory whose name holds the control
# character $1, run setup against it, and assert the run is refused with
# the reason named and NOTHING written. $2 is how that character must be
# shown in the one-line diagnostic.
_assert_control_char_refused() {
    local _dir="${BATS_TEST_TMPDIR}/ctl/d$1e" _dbx
    mkdir -p "${_dir}" "${HOME}/.config/ghostty"
    _dbx="${_dir}/distrobox"
    _fake_distrobox "${_dbx}"
    assert [ -x "${_dbx}" ]
    run "${SETUP}" --distrobox "${_dbx}"
    assert_failure 1
    assert_line "[ERROR] distrobox: ${BATS_TEST_TMPDIR}/ctl/d$2e/distrobox holds a newline or carriage return, which cannot be written into the line-based ghostty config or ~/.tmux.conf (install distrobox at a path without one); nothing was written"
    assert [ ! -e "${CONFIG}" ]
    assert [ ! -e "${GHOSTTY}" ]
    assert [ ! -e "${TMUX_CONF}" ]
}

@test "#175r2: a distrobox path holding a newline is refused before anything is written" {
    _assert_control_char_refused $'\n' '\n'
}

@test "#175r2: a carriage return is refused the same way (it truncates the line just as badly)" {
    _assert_control_char_refused $'\r' '\r'
}

# The rule is about what can be WRITTEN, so it has to bite on the path
# setup resolves for itself, not only on the one the user names.
@test "#175r2: a distrobox found on PATH is held to the same rule as --distrobox" {
    local _dir="${BATS_TEST_TMPDIR}/nlpath/d"$'\n'"e"
    mkdir -p "${_dir}" "${HOME}/.config/ghostty"
    _fake_distrobox "${_dir}/distrobox"
    PATH="${_dir}:/usr/bin:/bin" run "${SETUP}"
    assert_failure 1
    assert_line --partial "holds a newline or carriage return"
    assert [ ! -e "${CONFIG}" ]
    assert [ ! -e "${GHOSTTY}" ]
}

# The whole point of the absolute path: the command survives the reduced
# PATH a desktop session hands its terminal. The control case first proves
# that PATH really cannot reach this distrobox by name, so the positive
# case cannot be vacuous.
@test "#175: the written command runs under the reduced PATH of a desktop session, where the bare name does not" {
    mkdir -p "${HOME}/.config/ghostty"
    run "${SETUP}"
    assert_success
    local _cmd
    _cmd="$(sed -n 's/^command = //p' "${GHOSTTY}")"
    assert_equal "${_cmd}" "'${DISTROBOX}' enter dev -- tmux new -A -s main"

    # Control: this PATH has no distrobox by name.
    run -127 env -i PATH=/usr/bin:/bin /bin/sh -c 'distrobox enter dev -- tmux new -A -s main'
    assert_failure 127

    # The delivered command, run exactly as ghostty would run it.
    run env -i PATH=/usr/bin:/bin /bin/sh -c "${_cmd}"
    assert_success
    run cat "${DISTROBOX}.log"
    assert_line "enter dev -- tmux new -A -s main"
}

@test "rewriting an existing profile keeps its file mode" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n' >"${GHOSTTY}"
    chmod 0640 "${GHOSTTY}"
    printf 'set -g mouse on\n' >"${TMUX_CONF}"
    chmod 0664 "${TMUX_CONF}"
    run "${SETUP}" --terminal ghostty --tmux host
    assert_success
    assert_equal "$(stat -c '%a' "${GHOSTTY}")" "640"
    assert_equal "$(stat -c '%a' "${TMUX_CONF}")" "664"
    run "${SETUP}" --auto-enter no
    assert_success
    assert_equal "$(stat -c '%a' "${GHOSTTY}")" "640"
    assert_equal "$(stat -c '%a' "${TMUX_CONF}")" "664"
}

# --- errexit (issue #195) ----------------------------------------------------

@test "setup.sh runs under set -euo pipefail (one set line, errexit included)" {
    run grep -E '^set -[a-z]+( pipefail)?$' "${SETUP}"
    assert_success
    assert_output 'set -euo pipefail'
}

# lib/enter.sh enter_block_count, which _block_write reads. `grep -c` exits
# 1 on "no match" (expected: the count is 0) and 2 on a real error, which
# must reach the caller instead of being swallowed (codex round 1 on PR
# #214). A `grep` stand-in first on PATH produces the error.
@test "enter_block_count prints 0 and succeeds under errexit when no block is present" {
    printf 'font-size = 12\n' >"${BATS_TEST_TMPDIR}/cfg"
    run bash -c 'set -euo pipefail; source "$1/enter.sh"; enter_block_count "$2"; printf "reached\n"' \
        _ "${LIB_DIR}" "${BATS_TEST_TMPDIR}/cfg"
    assert_success
    assert_line --index 0 "0"
    assert_line --index 1 "reached"
}

@test "enter_block_count returns grep's error status instead of a count" {
    local _bin="${BATS_TEST_TMPDIR}/grepbin"
    mkdir -p "${_bin}"
    printf '#!/usr/bin/env bash\nexit 2\n' >"${_bin}/grep"
    chmod +x "${_bin}/grep"
    printf 'font-size = 12\n' >"${BATS_TEST_TMPDIR}/cfg"
    run bash -c 'source "$1/enter.sh"; PATH="$3:${PATH}"; enter_block_count "$2"' \
        _ "${LIB_DIR}" "${BATS_TEST_TMPDIR}/cfg" "${_bin}"
    assert_failure 2
}
