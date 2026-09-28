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
#     `command = <distrobox> enter <box> -- tmux new -A -s main`; tmux host ->
#     `command = tmux new -A -s main` plus a managed block in ~/.tmux.conf
#     (`set -g default-command "<distrobox> enter <box>"`). Re-runs are
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

    CMD_INSIDE="command = ${DISTROBOX} enter dev -- tmux new -A -s main"
    CMD_HOST="command = tmux new -A -s main"
    TMUX_BODY="set -g default-command \"${DISTROBOX} enter dev\""
}

# Install an executable stand-in for distrobox at $1. setup.sh only
# RESOLVES and writes its path, so the stand-in never has to do anything;
# it records its arguments so a case that runs the managed command can
# prove which binary answered.
_fake_distrobox() {
    mkdir -p "$(dirname -- "$1")"
    cat >"$1" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$1.log"
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
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: command = ${DISTROBOX} enter work -- tmux new -A -s main)"
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
    assert_line "command = ${DISTROBOX} enter dev -- tmux new -A -s main"
    refute_line "command = distrobox enter dev -- tmux new -A -s main"
}

@test "#175: --tmux host names the absolute distrobox path in the ~/.tmux.conf default-command too" {
    run "${SETUP}" --terminal ghostty --tmux host
    assert_success
    assert_line "[INFO] distrobox: ${DISTROBOX} (absolute path written into the managed command)"
    run cat "${TMUX_CONF}"
    assert_line "set -g default-command \"${DISTROBOX} enter dev\""
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
    assert_line "command = ${_link_dir}/distrobox enter dev -- tmux new -A -s main"
    refute_line --partial "${_real}"
}

@test "#175: with no distrobox on PATH the command falls back to the bare name and setup warns about a desktop launch" {
    mkdir -p "${HOME}/.config/ghostty"
    PATH="/usr/bin:/bin" run "${SETUP}"
    assert_success
    assert_line "[WARN] distrobox: not found on PATH; the managed command falls back to the bare name (a terminal launched from the desktop may not find it - install distrobox, then re-run: just box setup)"
    run cat "${GHOSTTY}"
    assert_line "command = distrobox enter dev -- tmux new -A -s main"
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
    assert_equal "${_cmd}" "${DISTROBOX} enter dev -- tmux new -A -s main"

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
