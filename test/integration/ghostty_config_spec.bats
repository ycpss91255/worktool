#!/usr/bin/env bats
# test/integration/ghostty_config_spec.bats - the managed block a real
# ghostty reads back (M3, issue #172; integration tier, GHOSTTY group)
#
# WHAT THIS PROVES
#   Layer 1 of the "open a window -> enter the box -> fish" chain, the
#   half that needs no display: what `just box setup` writes into
#   $XDG_CONFIG_HOME/ghostty/config is a config a REAL ghostty accepts and
#   resolves to exactly the command #5 promises.
#
#     - `ghostty +validate-config --config-file=<the written file>` exits 0:
#       the delivered managed block (marker lines included - they are `#`
#       comments to ghostty) parses.
#     - `ghostty +show-config` under XDG_CONFIG_HOME reports
#       `command = <distrobox> enter dev` - the
#       EFFECTIVE value ghostty would run, not merely the text on disk.
#       Since issue #175 `<distrobox>` is the ABSOLUTE path setup.sh
#       resolved, not the bare name: a terminal the desktop starts
#       inherits the systemd user manager's PATH, which does not hold
#       ~/.local/bin. The case asserts the absolute form AND refutes the
#       bare one. Since round 1 that path is also a SINGLE-QUOTED shell
#       word (ghostty hands a `command` without a `direct:` prefix to
#       `/bin/sh -c`), and one case runs the value a real ghostty reports
#       through that same shell; with nothing to resolve the run is
#       refused rather than written.
#     - the other setup decisions travel the same way: `--box work` names
#       that box. Since issue #179 nothing follows `enter <box>`: no tmux
#       is started for the terminal, so a case refutes any tmux in the
#       effective command.
#     - the assertion is not vacuous: after `--auto-enter no` removes the
#       block, ghostty reports no such command, and a config with a bogus
#       key is REFUSED by +validate-config. Both are the control cases that
#       would catch a +show-config / +validate-config that always says yes.
#
# WHY A SEPARATE GROUP
#   ghostty only exists in the Ubuntu 26.04 (resolute) archive, so this
#   spec runs in its own image (dockerfile/Dockerfile.ghostty) instead of
#   the alpine test image; `script/test/test.sh --integration` runs both
#   groups (the tier rules - required spec present and non-empty, at least
#   one case, no skip - apply to each). No display, no docker daemon and no
#   distrobox are needed here: layer 2 (a real window entering a real box)
#   is test/system/real_engine_spec.bats.
#
# NO HANG
#   Every ghostty call is wrapped in `timeout -k`; none of them opens a
#   window (`+validate-config` / `+show-config` are pure CLI actions), so
#   the budget below is generous on purpose and never reached in practice.

load "${BATS_TEST_DIRNAME}/../helper/common"

# Hard bound (seconds) on every ghostty CLI action; SIGKILL 5s later.
GHOSTTY_TIMEOUT=60

setup() {
    SETUP="${REPO_ROOT}/script/box/setup.sh"

    # Throwaway HOME / XDG_CONFIG_HOME: setup.sh writes there and ghostty
    # reads from there, so the real home is never touched. The ghostty dir
    # exists up front so setup.sh's terminal default detects ghostty.
    HOME="${BATS_TEST_TMPDIR}/home"
    export HOME
    XDG_CONFIG_HOME="${HOME}/.config"
    export XDG_CONFIG_HOME
    mkdir -p "${XDG_CONFIG_HOME}/ghostty"
    GHOSTTY_CONFIG="${XDG_CONFIG_HOME}/ghostty/config"

    # Issue #175: this image has no distrobox of its own, so each case
    # installs one where a user's would be - outside the system PATH - and
    # that absolute path is what setup.sh must hand to ghostty.
    DBX_DIR="${BATS_TEST_TMPDIR}/local/bin"
    DISTROBOX="${DBX_DIR}/distrobox"
    mkdir -p "${DBX_DIR}"
    printf '#!/bin/sh\nexit 0\n' >"${DISTROBOX}"
    chmod +x "${DISTROBOX}"
    PATH="${DBX_DIR}:${PATH}"
    export PATH

    # What #5 / doc/enter.md promise the terminal runs, with the default
    # box. The path is a single-quoted shell word (issue #175 round 1):
    # ghostty runs a `command` without a `direct:` prefix through
    # `/bin/sh -c`, so the value is shell source.
    EXPECTED_COMMAND="'${DISTROBOX}' enter dev"
}

# Every ghostty call goes through here: a hard bound so a wedged ghostty
# can never hold a case open. Exit status is ghostty's (124 on timeout).
_ghostty() {
    timeout -k 5 "${GHOSTTY_TIMEOUT}" ghostty "$@"
}

# Echo the lines $2.. into the TAP stream (fd 3 is bats' original stdout;
# `# ` keeps the stream TAP-clean) and into the case's own output,
# prefixed with $1.
_log_lines() {
    local _tag="$1" _l
    shift
    for _l in "$@"; do
        printf '# %s: %s\n' "${_tag}" "${_l}" >&3
        echo "${_tag}: ${_l}"
    done
}

# --- preflight: this really is the ghostty group -----------------------------

@test "preflight: a real ghostty is on PATH and reports its version" {
    run _ghostty +version
    assert_success
    assert_line --regexp '^Ghostty [0-9]+\.[0-9]+'
    _log_lines ghostty "${lines[0]}"
}

# --- the delivered managed block is valid ghostty config ---------------------

@test "setup.sh writes a ghostty config that +validate-config accepts" {
    run "${SETUP}"
    assert_success
    assert [ -f "${GHOSTTY_CONFIG}" ]
    # --config-file exists for +validate-config (it does not for
    # +show-config, which is why the cases below go through XDG_CONFIG_HOME).
    run _ghostty +validate-config --config-file="${GHOSTTY_CONFIG}"
    assert_success
}

@test "+show-config resolves the delivered block to the promised enter command" {
    run "${SETUP}"
    assert_success
    run _ghostty +show-config
    assert_success
    assert_line "command = ${EXPECTED_COMMAND}"
    _log_lines effective "command = ${EXPECTED_COMMAND}"
}

@test "#179: the effective command starts no tmux, on the host or in the box" {
    run "${SETUP}"
    assert_success
    run _ghostty +show-config
    assert_success
    assert_line "command = ${EXPECTED_COMMAND}"
    refute_line --regexp '^command = .*tmux'
}

@test "+show-config follows setup.sh --box work (the box name reaches ghostty)" {
    run "${SETUP}" --box work
    assert_success
    run _ghostty +show-config
    assert_success
    assert_line "command = '${DISTROBOX}' enter work"
}

# --- #175: the command ghostty resolves names an ABSOLUTE distrobox ---------

@test "#175: the effective command ghostty resolves is an ABSOLUTE distrobox path, not the bare name" {
    run "${SETUP}"
    assert_success
    run _ghostty +show-config
    assert_success
    assert_line "command = ${EXPECTED_COMMAND}"
    # The shape the real machine failed on: a desktop-launched terminal
    # inherits a PATH without ~/.local/bin and dies with `not found`.
    refute_line 'command = distrobox enter dev'
    _log_lines effective "${EXPECTED_COMMAND}"
}

@test "#175: the absolute-path command is still a config +validate-config accepts" {
    run "${SETUP}"
    assert_success
    run grep -qxF "command = ${EXPECTED_COMMAND}" "${GHOSTTY_CONFIG}"
    assert_success
    run _ghostty +validate-config --config-file="${GHOSTTY_CONFIG}"
    assert_success
}

@test "#175r1: with no distrobox on PATH setup refuses the run instead of writing a command it knows cannot work" {
    PATH="/usr/bin:/bin" run "${SETUP}"
    assert_failure 1
    assert_line --partial "[ERROR] distrobox: not found on PATH"
    assert [ ! -e "${GHOSTTY_CONFIG}" ]
}

# --- #175 round 1: a REAL ghostty resolves the quoted path back ---------------
#
# The value ghostty reports is what it hands to `/bin/sh -c`, so the case
# below runs that exact string: an install path holding a space, a `$` or a
# quote must still reach the one binary, and must not run anything else.

@test "#175r2: a distrobox path holding a newline is refused, because ghostty could not parse what it would write" {
    local _dir="${BATS_TEST_TMPDIR}/nl/d"$'\n'"e" _dbx
    mkdir -p "${_dir}"
    _dbx="${_dir}/distrobox"
    printf '#!/bin/sh\nexit 0\n' >"${_dbx}"
    chmod +x "${_dbx}"

    run "${SETUP}" --distrobox "${_dbx}"
    assert_failure 1
    assert_line --partial "holds a newline or carriage return"
    assert [ ! -e "${GHOSTTY_CONFIG}" ]

    # The check bites: this is the file setup would have written, and a
    # real ghostty refuses it - the managed body is split across two
    # lines, so the second one is not a key it knows.
    printf "command = '%s' enter dev\n" "${_dbx}" >"${GHOSTTY_CONFIG}"
    run _ghostty +validate-config --config-file="${GHOSTTY_CONFIG}"
    assert_failure
    assert_output --partial 'unknown field'
    _log_lines would-have-been-refused "${lines[@]}"
}

@test "#175r1: a distrobox path with spaces and metacharacters survives ghostty and the shell it hands the command to" {
    local _sentinel="${BATS_TEST_TMPDIR}/pwned"
    local _dir="${BATS_TEST_TMPDIR}/q/d \$(touch ${_sentinel}) \"q\"" _dbx _cmd
    mkdir -p "${_dir}"
    _dbx="${_dir}/distrobox"
    cat >"${_dbx}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$0.log"
EOF
    chmod +x "${_dbx}"

    run "${SETUP}" --distrobox "${_dbx}"
    assert_success
    run _ghostty +validate-config --config-file="${GHOSTTY_CONFIG}"
    assert_success

    # The EFFECTIVE value, read back from a real ghostty ...
    run _ghostty +show-config
    assert_success
    assert_line "command = '${_dbx}' enter dev"
    _cmd="$(printf '%s\n' "${lines[@]}" | sed -n 's/^command = //p')"
    _log_lines effective "${_cmd}"

    # ... run exactly the way ghostty runs it.
    run env -i PATH=/usr/bin:/bin /bin/sh -c "${_cmd}"
    assert_success
    run cat "${_dbx}.log"
    assert_line "enter dev"
    assert [ ! -e "${_sentinel}" ]
}

# --- control cases: the two assertions above can fail ------------------------

@test "after setup.sh --auto-enter no there is no enter command left for ghostty to run" {
    run "${SETUP}"
    assert_success
    run _ghostty +show-config
    assert_line "command = ${EXPECTED_COMMAND}"
    run "${SETUP}" --auto-enter no
    assert_success
    run _ghostty +show-config
    assert_success
    refute_line "command = ${EXPECTED_COMMAND}"
    refute_line --partial 'distrobox enter'
}

@test "+validate-config refuses a config ghostty cannot parse (the check bites)" {
    printf 'not-a-ghostty-key = 1\n' >"${GHOSTTY_CONFIG}"
    run _ghostty +validate-config --config-file="${GHOSTTY_CONFIG}"
    assert_failure
    # ghostty's own words, so a `ghostty` that is merely missing (exit 127)
    # can never satisfy this case.
    assert_output --partial 'not-a-ghostty-key: unknown field'
    _log_lines refused "${lines[@]}"
}
