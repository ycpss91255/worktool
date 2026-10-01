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
#     else none), box <name> (default dev). There is NO tmux decision
#     (issue #179): no --tmux option, no `tmux` key, and ~/.tmux.conf is
#     never read or written.
#   - The decisions land in ONE state file, $XDG_CONFIG_HOME/worktool/config
#     (default ~/.config/worktool/config): `<key>=<value>` plus
#     `<key>.source=default|user` per key. User choices persist across runs;
#     default keys are recomputed on every run.
#   - auto-enter yes + terminal ghostty writes ONE managed block (begin/end
#     marker lines) into $XDG_CONFIG_HOME/ghostty/config:
#     `command = '<distrobox>' enter <box>` - the terminal lands in the box's
#     own login shell (fish), with no tmux in between (issue #179). Re-runs
#     are idempotent (the block is replaced in place, never duplicated); user
#     content around the block is preserved.
#   - auto-enter no removes the ghostty managed block and reports it.
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
#   (b) The managed body is shell SOURCE, so the path is written as a
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

    # Issue #175 round 1: the body is shell source, so the path is QUOTED.
    # ghostty runs its `command` through /bin/sh -c, hence a single-quoted
    # word. Issue #179: nothing follows `enter <box>` - no tmux.
    CMD_ENTER="command = '${DISTROBOX}' enter dev"
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

@test "defaults (no ghostty dir): yes / none / dev, each logged as (default), state file written with sources, no tmux key" {
    run "${SETUP}"
    assert_success
    assert_line "[INFO] auto-enter: yes (default)"
    assert_line "[INFO] terminal: none (default)"
    assert_line "[INFO] box: dev (default)"
    refute_line --partial "tmux"
    assert_line "[INFO] wrote: ${CONFIG}"
    run cat "${CONFIG}"
    assert_line "auto-enter=yes"
    assert_line "auto-enter.source=default"
    assert_line "terminal=none"
    assert_line "terminal.source=default"
    refute_line --partial "tmux"
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

# --- #199 r3-r5: setup owns only its own keys in the shared state file --
# The state file has several writers (setup: the four decisions; assemble:
# home / home.source; the user: link= lines). setup must update its own
# keys in place and keep every other byte: comments, blank and
# whitespace-only lines, link= entries (duplicates too), the box home, keys
# a later version may add, CRLF lines, trailing blank lines and a missing
# final newline. The matrix is setup run x EOF framing x (append: two of
# setup's keys are new | replace-only: all of them are already there), and
# every case compares the whole file byte-for-byte (cmp) with the file it
# must be: `run cat` / `$(...)` drop trailing newlines and cannot see the
# framing. Only the replace-only half can see a writer that normalises the
# final newline (an appended key always ends the file with one); the
# mutation spec (config_mutation_spec) proves each half fails on the
# mutant it is meant to see.

# EOF framings, one `<name>|<tail>` per line (printf %b strings).
_framings() {
    printf '%s\n' \
        'nl|link=.config/foo\n' \
        'nonl|link=.config/foo' \
        'blanks|link=.config/foo\n\n\n' \
        'ws|link=.config/foo\n  \t ' \
        'crlf|# crlf note\r\nlink=.config/foo\r\n' \
        'crlf-nonl|# crlf note\r\nlink=.config/foo\r' \
        'crlf-blanks|link=.config/foo\r\n\r\n\r\n' \
        'crlf-ws|link=.config/foo\r\n  \t \r'
}

# The setup runs: `<args>|<auto-enter src>|<terminal src>|<tmux src>|<box src>`
# (what each run must leave, starting from tmux=host / box=dev by the user).
_runs() {
    printf '%s\n' \
        '|yes default|none default|host user|dev user' \
        '--terminal none --box work|yes default|none user|host user|work user' \
        '--auto-enter no|no user|none default|host user|dev user'
}

_HEAD='# my own notes about worktool\n\nlink=~/.aws\n'

# The body (printf %b) holding setup's keys: $1 auto-enter $2 its source
# $3 terminal $4 its source (both lines left out when $1 is empty), $5 tmux
# $6 its source, $7 box $8 its source, $9 extra lines after box.source.
_body() {
    local _ae=''
    [[ -z "$1" ]] || _ae="auto-enter=$1\\nauto-enter.source=$2\\nterminal=$3\\nterminal.source=$4\\n"
    printf '%s' "${_HEAD}${_ae}tmux=$5\\ntmux.source=$6\\nfuture-key=some value = with = inside\\nbox=$7\\nbox.source=$8\\n$9link=~/.aws\\n   \\n"
}

# Run every setup run x every framing, the input made by `_body` with
# (\$1 = append | replace); fail naming the first case whose bytes differ.
_matrix() {
    local _mode="$1" _name _tail _sep _row _want _in
    local -a _c _opts _ae _te _tm _bx
    while IFS='|' read -r _name _tail; do
        while IFS= read -r _row; do
            IFS='|' read -r -a _c <<<"${_row}"
            read -r -a _opts <<<"${_c[0]}"
            read -r -a _ae <<<"${_c[1]}"
            read -r -a _te <<<"${_c[2]}"
            read -r -a _tm <<<"${_c[3]}"
            read -r -a _bx <<<"${_c[4]}"
            if [[ "${_mode}" == append ]]; then
                _in="$(_body '' '' '' '' host user dev user 'box=dev\n')${_tail}"
                _sep=''
                [[ "${_tail}" == *'\n' ]] || _sep='\n'
                _want="$(_body '' '' '' '' "${_tm[0]}" "${_tm[1]}" "${_bx[0]}" "${_bx[1]}" '')${_tail}${_sep}"
                _want+="auto-enter=${_ae[0]}\\nauto-enter.source=${_ae[1]}\\nterminal=${_te[0]}\\nterminal.source=${_te[1]}\\n"
            else
                _in="$(_body yes default none default host user dev user 'box=dev\n')${_tail}"
                _want="$(_body "${_ae[0]}" "${_ae[1]}" "${_te[0]}" "${_te[1]}" "${_tm[0]}" "${_tm[1]}" "${_bx[0]}" "${_bx[1]}" '')${_tail}"
            fi
            mkdir -p "$(dirname -- "${CONFIG}")"
            printf '%b' "${_in}" >"${CONFIG}"
            printf '%b' "${_want}" >"${BATS_TEST_TMPDIR}/expected"
            "${SETUP}" "${_opts[@]}" >/dev/null 2>&1 \
                || { echo "setup failed: ${_mode} ${_name} ${_c[0]:-<defaults>}"; return 1; }
            cmp -- "${BATS_TEST_TMPDIR}/expected" "${CONFIG}" \
                || { echo "bytes differ: ${_mode} ${_name} ${_c[0]:-<defaults>}"; return 1; }
        done < <(_runs)
    done < <(_framings)
}

@test "#199 r4: every setup run x every EOF framing, appending two keys, keeps every foreign byte" {
    run _matrix append
    assert_success
}

@test "#199 r5: every setup run x every EOF framing, replace-only (all keys present), keeps every byte" {
    run _matrix replace
    assert_success
}

@test "#199 r4: a CRLF line of one of setup's own keys is refused (exit 1) and the file is left byte-for-byte" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'link=~/.aws\r\nterminal=none\r\nterminal.source=user\n' >"${CONFIG}"
    cp "${CONFIG}" "${BATS_TEST_TMPDIR}/expected"
    run "${SETUP}"
    assert_failure 1
    assert_output --partial "invalid value"
    run cmp -- "${BATS_TEST_TMPDIR}/expected" "${CONFIG}"
    assert_success
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
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'link=~/.aws\ntmux=host\ntmux.source=user\n' >"${CONFIG}"
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
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_ENTER})"
    run cat "${GHOSTTY}"
    assert_line --index 0 "${BEGIN}"
    assert_line --index 1 "${CMD_ENTER}"
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
    assert_line "[INFO] wrote: ${_xdg}/ghostty/config (managed block: ${CMD_ENTER})"
    assert [ -f "${_xdg}/worktool/config" ]
    assert [ ! -e "${CONFIG}" ]
    assert [ ! -e "${GHOSTTY}" ]
}

# --- user overrides ----------------------------------------------------------

@test "user overrides are logged as (user) and stored with source=user" {
    run "${SETUP}" --auto-enter yes --terminal ghostty --box work
    assert_success
    assert_line "[INFO] auto-enter: yes (user)"
    assert_line "[INFO] terminal: ghostty (user)"
    assert_line "[INFO] box: work (user)"
    run cat "${CONFIG}"
    assert_line "auto-enter.source=user"
    assert_line "terminal=ghostty"
    assert_line "terminal.source=user"
    assert_line "box=work"
    assert_line "box.source=user"
}

@test "--key=value spelling is accepted for every value option" {
    run "${SETUP}" --auto-enter=yes --terminal=ghostty --box=work
    assert_success
    assert_line "[INFO] terminal: ghostty (user)"
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
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: command = '${DISTROBOX}' enter work)"
}

# --- ghostty block: exactly once, idempotent, user content preserved ---------

@test "the ghostty block is written exactly once and a re-run is idempotent (unchanged)" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n' >"${GHOSTTY}"
    run "${SETUP}" --terminal ghostty
    assert_success
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_ENTER})"
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
    assert_line --index 2 "${CMD_ENTER}"
    assert_line --index 3 "${END}"
    assert_equal "${#lines[@]}" 4
}

@test "a changed decision replaces the block in place: user lines before and after it survive" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n%s\n%s\n%s\nfont-size = 12\n' \
        "${BEGIN}" "${CMD_ENTER}" "${END}" >"${GHOSTTY}"
    run "${SETUP}" --terminal ghostty --box work
    assert_success
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: command = '${DISTROBOX}' enter work)"
    assert_equal "$(_block_count "${GHOSTTY}")" "1"
    run cat "${GHOSTTY}"
    assert_line --index 0 "theme = dark"
    assert_line --index 1 "${BEGIN}"
    assert_line --index 2 "command = '${DISTROBOX}' enter work"
    assert_line --index 3 "${END}"
    assert_line --index 4 "font-size = 12"
    assert_equal "${#lines[@]}" 5
    refute_line "${CMD_ENTER}"
}

# --- #179: no tmux decision, and ~/.tmux.conf is never touched --------------
#
# The M3 real-machine acceptance landed on the HOST: the old managed command
# ended in `tmux new -A -s main`, distrobox shares /tmp with the host, and
# `-A` attached to the host's tmux server. The terminal now enters the box
# and gets its login shell; tmux is something the user starts in the box.

@test "#179: the ghostty managed command enters the box and runs nothing after it (no tmux)" {
    run "${SETUP}" --terminal ghostty
    assert_success
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_ENTER})"
    refute_line --partial "tmux"
    run cat "${GHOSTTY}"
    assert_line "${CMD_ENTER}"
    refute_line --partial "tmux"
    refute_line --partial " -- "
}

@test "#179: --tmux is no longer an option: refused as unknown, exit 2, nothing written" {
    run "${SETUP}" --tmux inside
    assert_failure 2
    assert_output "setup.sh: unknown option '--tmux' (see --help)"
    run "${SETUP}" --tmux=host
    assert_failure 2
    assert_output "setup.sh: unknown option '--tmux=host' (see --help)"
    assert [ ! -e "${CONFIG}" ]
}

@test "#179: ~/.tmux.conf is never written, read or cleaned, whatever the decisions" {
    printf 'set -g mouse on\n%s\nset -g default-command x\n%s\n' "${BEGIN}" "${END}" >"${TMUX_CONF}"
    chmod 0600 "${TMUX_CONF}"
    local _before
    _before="$(cat "${TMUX_CONF}")"
    run "${SETUP}" --terminal ghostty
    assert_success
    refute_line --partial ".tmux.conf"
    run "${SETUP}" --terminal none
    assert_success
    refute_line --partial ".tmux.conf"
    run "${SETUP}" --auto-enter no
    assert_success
    refute_line --partial ".tmux.conf"
    assert_equal "$(cat "${TMUX_CONF}")" "${_before}"
    assert_equal "$(stat -c '%a' "${TMUX_CONF}")" "600"
}

# --- #179 (codex round 4 on PR #232): the box's tmux environment -----------
#
# `distrobox enter` copies the caller's environment into the box, TMUX
# included: from a HOST tmux pane the box would get the host server's
# socket, whatever tmux binary runs. setup.sh keeps a managed block in
# distrobox's own user config (sourced by distrobox-enter before it copies
# the environment) that drops TMUX / TMUX_PANE for the box - on EVERY run:
# it is the box's isolation, not a terminal choice.

@test "#179: every run writes the distrobox.conf block that drops TMUX / TMUX_PANE for the box, and logs it" {
    local _conf="${HOME}/.config/distrobox/distrobox.conf" _body
    _body="$(bash -c 'source "$1" && enter_distrobox_conf_body dev' _ "${REPO_ROOT}/lib/enter.sh")"
    run "${SETUP}"
    assert_success
    assert_line "[INFO] wrote: ${_conf} (managed block: ${_body})"
    run cat "${_conf}"
    assert_line --index 0 "${BEGIN}"
    assert_line --index 1 "${_body}"
    assert_line --index 2 "${END}"
    assert_equal "${#lines[@]}" 3
}

@test "#179: the distrobox.conf block is kept by --terminal none and --auto-enter no, idempotent, user lines preserved" {
    local _conf="${HOME}/.config/distrobox/distrobox.conf" _first
    mkdir -p "$(dirname -- "${_conf}")"
    printf 'container_manager="docker"
' >"${_conf}"
    run "${SETUP}" --terminal ghostty
    assert_success
    _first="$(cat "${_conf}")"
    assert_equal "$(_block_count "${_conf}")" "1"
    run "${SETUP}" --terminal none
    assert_success
    assert_line "[INFO] unchanged: ${_conf} (managed block already up to date)"
    run "${SETUP}" --auto-enter no
    assert_success
    assert_line "[INFO] unchanged: ${_conf} (managed block already up to date)"
    assert_equal "$(cat "${_conf}")" "${_first}"
    run cat "${_conf}"
    assert_line --index 0 'container_manager="docker"'
}

@test "#179: the distrobox.conf block names the chosen box, and follows a changed --box" {
    local _conf="${HOME}/.config/distrobox/distrobox.conf"
    run "${SETUP}" --box work
    assert_success
    run grep -c "!= 'work' ] || unset TMUX TMUX_PANE" "${_conf}"
    assert_output "1"
    run "${SETUP}" --box dev
    assert_success
    assert_equal "$(_block_count "${_conf}")" "1"
    run grep -c "!= 'dev' ] || unset TMUX TMUX_PANE" "${_conf}"
    assert_output "1"
    run grep -c "'work'" "${_conf}"
    assert_output "0"
}

@test "#179: --dry-run reports the distrobox.conf block it would write and writes nothing" {
    run "${SETUP}" --dry-run
    assert_success
    assert_line --partial "[INFO] dry-run: would write ${HOME}/.config/distrobox/distrobox.conf (managed block: "
    assert [ ! -e "${HOME}/.config/distrobox" ]
}

@test "#179: a tmux line an earlier worktool stored is ignored, not refused, and preserved as foreign state" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'tmux=host\ntmux.source=user\nbox=work\nbox.source=user\n' >"${CONFIG}"
    run "${SETUP}"
    assert_success
    assert_line "[INFO] box: work (user)"
    refute_line --partial "tmux"
    run cat "${CONFIG}"
    assert_line "tmux=host"
    assert_line "tmux.source=user"
    assert_line "box=work"
}

# --- auto-enter no: restore the host shell -----------------------------------

@test "--auto-enter no removes the ghostty managed block, reports it, keeps user content" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n' >"${GHOSTTY}"
    run "${SETUP}" --terminal ghostty
    assert_success
    assert_equal "$(_block_count "${GHOSTTY}")" "1"

    run "${SETUP}" --auto-enter no
    assert_success
    assert_line "[INFO] auto-enter: no (user)"
    assert_line "[INFO] removed: ${GHOSTTY} (managed block: ${CMD_ENTER})"
    assert_equal "$(_block_count "${GHOSTTY}")" "0"
    assert_equal "$(cat "${GHOSTTY}")" "theme = dark"
    run cat "${CONFIG}"
    assert_line "auto-enter=no"
    assert_line "auto-enter.source=user"
}

@test "--auto-enter no with nothing managed says so" {
    run "${SETUP}" --auto-enter no
    assert_success
    assert_line "[INFO] nothing to remove: ${GHOSTTY} (no managed block)"
    assert [ ! -e "${GHOSTTY}" ]
}

# --- dry-run -----------------------------------------------------------------

@test "--dry-run logs every decision and what it would write, and writes nothing" {
    mkdir -p "${HOME}/.config/ghostty"
    run "${SETUP}" --dry-run --box work
    assert_success
    assert_line "[INFO] auto-enter: yes (default)"
    assert_line "[INFO] terminal: ghostty (default)"
    assert_line "[INFO] box: work (user)"
    assert_line "[INFO] dry-run: would write ${CONFIG}"
    assert_line "[INFO] dry-run: would write ${GHOSTTY} (managed block: command = '${DISTROBOX}' enter work)"
    assert [ ! -e "${CONFIG}" ]
    assert [ ! -e "${GHOSTTY}" ]
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
    refute_output --partial "--tmux"
    refute_output --partial ".tmux.conf"
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
    printf 'terminal=sideways\nterminal.source=user\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for terminal (expected ghostty|none)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'terminal=sideways\nterminal.source=user')"
}

# --- #161 (2): every stored value is validated, whatever its source ----------

@test "a corrupt stored value whose source is default is refused too: exit 1, no file changed" {
    mkdir -p "$(dirname -- "${CONFIG}")" "${HOME}/.config/ghostty"
    printf 'terminal=sideways\nterminal.source=default\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for terminal (expected ghostty|none)"
    refute_line --partial "wrote:"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'terminal=sideways\nterminal.source=default')"
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
    printf 'terminal=none\nterminal.source=guess\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'guess' for terminal.source (expected default|user)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'terminal=none\nterminal.source=guess')"
}

# A key that IS present with an empty value is a stored value like any other:
# it is refused, never mistaken for an absent key (absent = default applies).
@test "an empty stored value is refused: a present key is validated even when its value is empty" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'terminal=\nterminal.source=user\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value '' for terminal (expected ghostty|none)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'terminal=\nterminal.source=user')"
    printf 'box=\nbox.source=user\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value '' for box (expected a container name: [A-Za-z0-9][A-Za-z0-9_.-]*)"
    printf 'terminal=none\nterminal.source=\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value '' for terminal.source (expected default|user)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'terminal=none\nterminal.source=')"
}

# Every LINE is validated, not just the first line per key: a corrupt
# duplicate hiding behind a valid first occurrence is refused too.
@test "a corrupt duplicate key is refused even when its first occurrence is valid" {
    mkdir -p "$(dirname -- "${CONFIG}")"
    printf 'terminal=none\nterminal=sideways\nterminal.source=user\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'sideways' for terminal (expected ghostty|none)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'terminal=none\nterminal=sideways\nterminal.source=user')"
    printf 'terminal=none\nterminal.source=user\nterminal.source=guess\n' >"${CONFIG}"
    run "${SETUP}"
    assert_failure 1
    assert_line "[ERROR] ${CONFIG}: invalid value 'guess' for terminal.source (expected default|user)"
    assert_equal "$(cat "${CONFIG}")" "$(printf 'terminal=none\nterminal.source=user\nterminal.source=guess')"
}

# --- #161 (1): terminal none never writes a terminal profile ------------------

@test "switching to --terminal none removes the ghostty block an earlier ghostty run left" {
    run "${SETUP}" --terminal ghostty
    assert_success
    assert_equal "$(_block_count "${GHOSTTY}")" "1"
    run "${SETUP}" --terminal none
    assert_success
    assert_line "[INFO] removed: ${GHOSTTY} (managed block: ${CMD_ENTER})"
    assert_equal "$(_block_count "${GHOSTTY}")" "0"
}

# --- #161 (3): exactly one managed block per file ----------------------------

# Issue #179 (codex round 4 on PR #232) supersedes #161's collapse: a file
# holding more than one block has malformed markers, and a rewrite of a
# malformed file is how user lines were lost (an orphan BEGIN swallowed the
# rest of the file). Every malformed shape is refused before anything is
# written; the full matrix is test/unit/managed_block_spec.bats.
@test "a file that already holds two managed blocks is refused, not collapsed: exit 1, the file unchanged" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n%s\n%s\n%s\nfont-size = 12\n%s\n%s\n%s\ntail = 1\n' \
        "${BEGIN}" "${CMD_ENTER}" "${END}" "${BEGIN}" "${CMD_ENTER}" "${END}" >"${GHOSTTY}"
    local _before
    _before="$(cat "${GHOSTTY}")"
    run "${SETUP}" --terminal ghostty
    assert_failure 1
    assert_line --partial "[ERROR] ${GHOSTTY}: malformed worktool managed block markers: 2 blocks (BEGIN at lines 2, 6)"
    assert_equal "$(cat "${GHOSTTY}")" "${_before}"
    assert [ ! -e "${CONFIG}" ]
}

@test "--auto-enter no refuses a file with two managed blocks the same way" {
    mkdir -p "${HOME}/.config/ghostty"
    printf '%s\n%s\n%s\ntheme = dark\n%s\n%s\n%s\n' \
        "${BEGIN}" "${CMD_ENTER}" "${END}" "${BEGIN}" "${CMD_ENTER}" "${END}" >"${GHOSTTY}"
    local _before
    _before="$(cat "${GHOSTTY}")"
    run "${SETUP}" --auto-enter no
    assert_failure 1
    refute_line --partial "removed:"
    assert_equal "$(cat "${GHOSTTY}")" "${_before}"
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
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_ENTER})"
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
    assert_line "command = '${DISTROBOX}' enter dev"
    refute_line "command = distrobox enter dev"
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
    assert_line "command = '${_link_dir}/distrobox' enter dev"
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
    assert_line "${CMD_ENTER}"
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

# --- #175 round 1 (b): the path is SHELL-QUOTED in the body -----------------
#
# The managed body is shell source, not argv: ghostty runs a `command`
# without a `direct:` prefix through `/bin/sh -c`. An install path holding a
# space, a `$`, a backtick or a quote would otherwise be split into words or
# change the meaning of the command outright.

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
    assert_equal "${_cmd}" "$(_squote "${_dbx}") enter dev"
    run env -i PATH=/usr/bin:/bin /bin/sh -c "${_cmd}"
    assert_success
    run cat "${_dbx}.log"
    assert_line "enter dev"
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

@test "#175r1: a distrobox path containing a SINGLE QUOTE is quoted and still runs as one word" {
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
    assert_line "[ERROR] distrobox: ${BATS_TEST_TMPDIR}/ctl/d$2e/distrobox holds a newline or carriage return, which cannot be written into the line-based ghostty config (install distrobox at a path without one); nothing was written"
    assert [ ! -e "${CONFIG}" ]
    assert [ ! -e "${GHOSTTY}" ]
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
    assert_equal "${_cmd}" "'${DISTROBOX}' enter dev"

    # Control: this PATH has no distrobox by name.
    run -127 env -i PATH=/usr/bin:/bin /bin/sh -c 'distrobox enter dev'
    assert_failure 127

    # The delivered command, run exactly as ghostty would run it.
    run env -i PATH=/usr/bin:/bin /bin/sh -c "${_cmd}"
    assert_success
    run cat "${DISTROBOX}.log"
    assert_line "enter dev"
}

@test "rewriting an existing profile keeps its file mode" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n' >"${GHOSTTY}"
    chmod 0640 "${GHOSTTY}"
    run "${SETUP}" --terminal ghostty
    assert_success
    assert_equal "$(stat -c '%a' "${GHOSTTY}")" "640"
    run "${SETUP}" --auto-enter no
    assert_success
    assert_equal "$(stat -c '%a' "${GHOSTTY}")" "640"
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

# --- #178: the remaining uncovered setup.sh paths ----------------------------
#
# Five paths the M3 acceptance audit found unguarded or only partly guarded:
# config_write_atomic failure, mode preservation, dry-run removal and
# unchanged profiles. Multi-block refusal is covered in managed_block_spec.bats.
# No host tmux config is managed after #179.
#
# Scope: this section is the unit layer of #178 only. The acceptance layer
# (script/verify/setup.sh items, doc/acceptance.md criteria and the
# test/unit/verify_setup_spec.bats degraded-copy cases) is tracked in #231,
# as recorded in the #178 issue body.

# Install a stand-in for command $1 (mv or mktemp) first on the returned
# PATH directory: it exits 1 when its LAST argument is $FAIL_TARGET (mv's
# destination) or "$FAIL_TARGET.XXXXXX" (mktemp's template), and runs the
# real command otherwise. Prints the directory to prepend to PATH.
_fail_bin() {
    local _dir="${BATS_TEST_TMPDIR}/failbin" _real
    _real="$(command -v "$1")"
    mkdir -p "${_dir}"
    printf "#!/bin/sh\n_real='%s'\n" "${_real}" >"${_dir}/$1"
    cat >>"${_dir}/$1" <<'STUB'
for _a in "$@"; do _last="$_a"; done
case "${_last:-}" in "${FAIL_TARGET}"|"${FAIL_TARGET}.XXXXXX") exit 1 ;; esac
exec "${_real}" "$@"
STUB
    chmod +x "${_dir}/$1"
    printf '%s\n' "${_dir}"
}

# Number of lines of text $2 (a run's output) exactly equal to $1. grep -c
# already prints 0 on "no match" (exit 1); only a real error (exit >= 2)
# is passed on to the caller.
_count_line() {
    local _rc=0
    grep -cxF -- "$1" <<<"$2" || _rc=$?
    if [[ "${_rc}" -gt 1 ]]; then
        return "${_rc}"
    fi
}

# _count_line itself: "no match" (grep exit 1) is a count of 0, a real grep
# error (exit 2) must reach the caller instead of being swallowed (codex
# round 1 on PR #227). A `grep` stand-in first on PATH produces the error.
@test "#178: _count_line prints 0 and succeeds when no line matches" {
    run _count_line "absent" $'one\ntwo'
    assert_success
    assert_output "0"
}

@test "#178: _count_line returns grep's error status instead of a count" {
    local _bin="${BATS_TEST_TMPDIR}/grepbin"
    mkdir -p "${_bin}"
    printf '#!/usr/bin/env bash\nexit 2\n' >"${_bin}/grep"
    chmod +x "${_bin}/grep"
    PATH="${_bin}:${PATH}" run _count_line "one" $'one\ntwo'
    assert_failure 2
}

# Seed the ghostty config with a user line, the current managed block (via
# a real setup run) and a user line after it; keep a reference copy.
_seed_managed_ghostty() {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n' >"${GHOSTTY}"
    run "${SETUP}" --terminal ghostty
    assert_success
    printf 'font-size = 12\n' >>"${GHOSTTY}"
    cp -p -- "${GHOSTTY}" "${BATS_TEST_TMPDIR}/ghostty.ref"
}

# 1. _write_atomic failure --------------------------------------------------

@test "#178: a profile write whose rename fails is reported once, exit 1, profile byte-identical, no temp file left" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n' >"${GHOSTTY}"
    cp -p -- "${GHOSTTY}" "${BATS_TEST_TMPDIR}/ghostty.ref"
    local _bin
    _bin="$(_fail_bin mv)"
    PATH="${_bin}:${PATH}" FAIL_TARGET="${GHOSTTY}" run "${SETUP}" --terminal ghostty
    assert_failure 1
    assert_equal "$(_count_line "[ERROR] failed to write ${GHOSTTY}" "${output}")" "1"
    refute_line --partial "wrote: ${GHOSTTY}"
    # The state file is written first and stays written.
    assert_line "[INFO] wrote: ${CONFIG}"
    cmp -- "${BATS_TEST_TMPDIR}/ghostty.ref" "${GHOSTTY}"
    run ls -A -- "${HOME}/.config/ghostty"
    assert_output "config"
}

@test "#178: a profile write whose temp file cannot be created is reported once, exit 1, profile byte-identical" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n' >"${GHOSTTY}"
    cp -p -- "${GHOSTTY}" "${BATS_TEST_TMPDIR}/ghostty.ref"
    local _bin
    _bin="$(_fail_bin mktemp)"
    PATH="${_bin}:${PATH}" FAIL_TARGET="${GHOSTTY}" run "${SETUP}" --terminal ghostty
    assert_failure 1
    assert_equal "$(_count_line "[ERROR] failed to write ${GHOSTTY}" "${output}")" "1"
    cmp -- "${BATS_TEST_TMPDIR}/ghostty.ref" "${GHOSTTY}"
    run ls -A -- "${HOME}/.config/ghostty"
    assert_output "config"
}

@test "#178: after a failed profile write, status shows the block absent and a re-run completes it" {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n' >"${GHOSTTY}"
    local _bin
    _bin="$(_fail_bin mv)"
    PATH="${_bin}:${PATH}" FAIL_TARGET="${GHOSTTY}" run "${SETUP}" --terminal ghostty
    assert_failure 1
    run "${REPO_ROOT}/script/box/status.sh"
    assert_success
    assert_line "ghostty: ${GHOSTTY} (managed block: absent)"

    run "${SETUP}" --terminal ghostty
    assert_success
    assert_line "[INFO] wrote: ${GHOSTTY} (managed block: ${CMD_INSIDE})"
    assert_equal "$(_block_count "${GHOSTTY}")" "1"
    run "${REPO_ROOT}/script/box/status.sh"
    assert_success
    assert_line "ghostty: ${GHOSTTY} (managed block: present)"
}

@test "#178: a state file write that fails is reported once, exit 1, no profile touched, no temp file left" {
    _seed_managed_ghostty
    cp -p -- "${CONFIG}" "${BATS_TEST_TMPDIR}/config.ref"
    local _bin
    _bin="$(_fail_bin mv)"
    PATH="${_bin}:${PATH}" FAIL_TARGET="${CONFIG}" run "${SETUP}" --terminal ghostty --box other
    assert_failure 1
    assert_equal "$(_count_line "[ERROR] failed to write ${CONFIG}" "${output}")" "1"
    refute_line --partial "wrote:"
    cmp -- "${BATS_TEST_TMPDIR}/config.ref" "${CONFIG}"
    cmp -- "${BATS_TEST_TMPDIR}/ghostty.ref" "${GHOSTTY}"
    run ls -A -- "${HOME}/.config/worktool"
    assert_output "config"
}

@test "#178: a block removal that fails is reported once, exit 1, profile byte-identical, no temp file left" {
    _seed_managed_ghostty
    local _bin
    _bin="$(_fail_bin mv)"
    PATH="${_bin}:${PATH}" FAIL_TARGET="${GHOSTTY}" run "${SETUP}" --auto-enter no
    assert_failure 1
    assert_equal "$(_count_line "[ERROR] failed to write ${GHOSTTY}" "${output}")" "1"
    refute_line --partial "removed: ${GHOSTTY}"
    cmp -- "${BATS_TEST_TMPDIR}/ghostty.ref" "${GHOSTTY}"
    run ls -A -- "${HOME}/.config/ghostty"
    assert_output "config"
}

# 2. _copy_mode ---------------------------------------------------------------

# Seed the ghostty config with mode $1, then write, rewrite and remove the
# managed block, asserting the mode after every step.
_assert_mode_kept() {
    mkdir -p "${HOME}/.config/ghostty"
    printf 'theme = dark\n' >"${GHOSTTY}"
    chmod "$1" "${GHOSTTY}"
    run "${SETUP}" --terminal ghostty
    assert_success
    assert_line --partial "[INFO] wrote: ${GHOSTTY} (managed block:"
    assert_equal "$(stat -c '%a' "${GHOSTTY}")" "$1"
    run "${SETUP}" --terminal ghostty --box other
    assert_success
    assert_line --partial "[INFO] wrote: ${GHOSTTY} (managed block:"
    assert_equal "$(stat -c '%a' "${GHOSTTY}")" "$1"
    run "${SETUP}" --auto-enter no
    assert_success
    assert_line --partial "[INFO] removed: ${GHOSTTY} (managed block:"
    assert_equal "$(stat -c '%a' "${GHOSTTY}")" "$1"
}

@test "#178: a 0644 ghostty config stays 0644 through write, rewrite and removal" {
    _assert_mode_kept 644
}

@test "#178: a 0600 ghostty config stays 0600 through write, rewrite and removal" {
    _assert_mode_kept 600
}

# 3. dry-run removal ----------------------------------------------------------

@test "#178: --dry-run --auto-enter no over a managed block reports it once and leaves every file byte-identical" {
    _seed_managed_ghostty
    cp -p -- "${CONFIG}" "${BATS_TEST_TMPDIR}/config.ref"
    local _inode
    _inode="$(stat -c '%i' "${GHOSTTY}")"
    run "${SETUP}" --dry-run --auto-enter no
    assert_success
    assert_equal "$(_count_line "[INFO] dry-run: would remove managed block from ${GHOSTTY}" "${output}")" "1"
    refute_line --partial "removed:"
    refute_line --partial "wrote:"
    cmp -- "${BATS_TEST_TMPDIR}/ghostty.ref" "${GHOSTTY}"
    cmp -- "${BATS_TEST_TMPDIR}/config.ref" "${CONFIG}"
    assert_equal "$(stat -c '%i' "${GHOSTTY}")" "${_inode}"
    run ls -A -- "${HOME}/.config/ghostty"
    assert_output "config"
}

@test "#178: --dry-run --terminal none over a managed block reports the removal and removes nothing" {
    _seed_managed_ghostty
    run "${SETUP}" --dry-run --terminal none
    assert_success
    assert_equal "$(_count_line "[INFO] dry-run: would remove managed block from ${GHOSTTY}" "${output}")" "1"
    refute_line --partial "removed:"
    cmp -- "${BATS_TEST_TMPDIR}/ghostty.ref" "${GHOSTTY}"
}

# 4. unchanged ----------------------------------------------------------------

@test "#178: a re-run with the same decisions does not rewrite the profile (no wrote line, same inode)" {
    _seed_managed_ghostty
    local _inode
    _inode="$(stat -c '%i' "${GHOSTTY}")"
    run "${SETUP}" --terminal ghostty
    assert_success
    assert_equal "$(_count_line "[INFO] unchanged: ${GHOSTTY} (managed block already up to date)" "${output}")" "1"
    refute_line --partial "wrote: ${GHOSTTY}"
    assert_equal "$(stat -c '%i' "${GHOSTTY}")" "${_inode}"
    cmp -- "${BATS_TEST_TMPDIR}/ghostty.ref" "${GHOSTTY}"
}

@test "#178: --dry-run over an up-to-date block says unchanged, not would write" {
    _seed_managed_ghostty
    run "${SETUP}" --dry-run --terminal ghostty
    assert_success
    assert_line "[INFO] unchanged: ${GHOSTTY} (managed block already up to date)"
    refute_line --partial "would write ${GHOSTTY}"
    cmp -- "${BATS_TEST_TMPDIR}/ghostty.ref" "${GHOSTTY}"
}

# 5. Multi-block files are refused before any write (issue #179).
# Covered by managed_block_spec.bats: malformed markers x operation x
# managed file, re-running setup on two managed blocks, and --dry-run refusal.
