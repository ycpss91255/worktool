#!/usr/bin/env bats
# test/unit/box_tmux_guard_spec.bats - the dev box's tmux guard (issue #179)
#
# WHAT THIS PROVES
#   `distrobox enter` copies the caller's environment into the box, TMUX
#   included. Entered from a HOST tmux pane, TMUX names the host server's
#   socket on the /tmp the box shares, and tmux prefers $TMUX over
#   TMUX_TMPDIR, so a `tmux` in the box would reach the HOST server (codex
#   round 1 on PR #232). box/tmux-guard.sh is the box's `tmux`: it keeps
#   TMUX only when it names a socket under
#   the box's own TMUX_TMPDIR, drops it otherwise, and refuses to run with
#   no TMUX_TMPDIR at all (tmux would fall back to the shared /tmp).
#
#   It sits AT /usr/bin/tmux, not merely ahead of it on PATH (codex round 2
#   on PR #232): a `/usr/bin/tmux` typed by path must go through it too. The
#   packaged binary is moved aside with dpkg-divert (/usr/bin/tmux.real), so
#   a later tmux package upgrade lands there and never overwrites the guard.
#
#   box/dev.ini is a plain distrobox-assemble manifest, so the guard reaches
#   the box as a base64 blob in an init hook. The first case pins that the
#   blob decodes to box/tmux-guard.sh byte for byte: the readable file is
#   the one source, the blob can never drift from it.
#
# HOW
#   The guard execs /usr/bin/tmux.real. Each case runs a copy whose exec target
#   is a fake that prints the TMUX / TMUX_TMPDIR it received and its
#   arguments, so what the real tmux would see is asserted directly.
#
# Written test-first: RED with no guard and no install hook in box/dev.ini.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    GUARD="${REPO_ROOT}/box/tmux-guard.sh"
    MANIFEST="${REPO_ROOT}/box/dev.ini"
    BOX_TMPDIR="/home/u/dev-box/.cache/tmux"
    FAKE="${BATS_TEST_TMPDIR}/real-tmux"
    cat >"${FAKE}" <<'EOF'
#!/bin/sh
printf 'TMUX=%s\n' "${TMUX-<unset>}"
printf 'TMUX_TMPDIR=%s\n' "${TMUX_TMPDIR-<unset>}"
for a in "$@"; do printf 'arg=%s\n' "$a"; done
EOF
    chmod 0755 "${FAKE}"
    UNDER_TEST="${BATS_TEST_TMPDIR}/tmux"
    sed "s|/usr/bin/tmux.real|${FAKE}|" "${GUARD}" >"${UNDER_TEST}"
    chmod 0755 "${UNDER_TEST}"
}

@test "box/dev.ini diverts the packaged tmux to /usr/bin/tmux.real before installing the guard" {
    local _divert _guard
    _divert="$(grep -nxF 'init_hooks=dpkg-divert --local --rename --divert /usr/bin/tmux.real --add /usr/bin/tmux' "${MANIFEST}")" \
        || fail "no dpkg-divert init hook for /usr/bin/tmux"
    _guard="$(grep -nE '^init_hooks=echo .* >/usr/bin/tmux ' "${MANIFEST}")" \
        || fail "no init hook installs the guard at /usr/bin/tmux"
    (( ${_divert%%:*} < ${_guard%%:*} )) || fail "the guard is installed before the divert"
}

@test "box/dev.ini installs box/tmux-guard.sh, byte for byte, AT /usr/bin/tmux (a path-typed /usr/bin/tmux is guarded too)" {
    local _hook _blob
    _hook="$(grep -E '^init_hooks=echo ' "${MANIFEST}")"
    [[ "${_hook}" =~ ^init_hooks=echo\ ([A-Za-z0-9+/=]+)\ \|\ base64\ -d\ \>/usr/bin/tmux\ \&\&\ chmod\ 0755\ /usr/bin/tmux$ ]] \
        || fail "unexpected install hook: '${_hook}'"
    _blob="${BASH_REMATCH[1]}"
    assert_equal "$(printf '%s' "${_blob}" | base64 -d | sha256sum)" "$(sha256sum <"${GUARD}")"
}

@test "box/dev.ini no longer relies on PATH order: nothing is installed at /usr/local/bin/tmux" {
    run grep -c '/usr/local/bin/tmux' "${MANIFEST}"
    assert_output "0"
}

@test "the guard execs the diverted real tmux at /usr/bin/tmux.real, not itself" {
    run grep -cE '^exec /usr/bin/tmux\.real "\$@"$' "${GUARD}"
    assert_success
    assert_output "1"
}

@test "TMUX naming the HOST server's socket (a host tmux pane) is dropped" {
    TMUX="/tmp/tmux-1000/default,4242,0" TMUX_TMPDIR="${BOX_TMPDIR}" run "${UNDER_TEST}" ls
    assert_success
    assert_line "TMUX=<unset>"
    assert_line "TMUX_TMPDIR=${BOX_TMPDIR}"
    assert_line "arg=ls"
}

@test "TMUX naming the box's own server (a box tmux pane) is kept" {
    local _own="${BOX_TMPDIR}/tmux-1000/default,77,1"
    TMUX="${_own}" TMUX_TMPDIR="${BOX_TMPDIR}" run "${UNDER_TEST}" split-window
    assert_success
    assert_line "TMUX=${_own}"
    assert_line "arg=split-window"
}

@test "a socket in a sibling directory that only shares the prefix is dropped" {
    TMUX="${BOX_TMPDIR}-evil/tmux-1000/default,1,0" TMUX_TMPDIR="${BOX_TMPDIR}" run "${UNDER_TEST}"
    assert_success
    assert_line "TMUX=<unset>"
}

@test "no TMUX at all runs tmux with the arguments verbatim" {
    run env -u TMUX TMUX_TMPDIR="${BOX_TMPDIR}" "${UNDER_TEST}" new-session -s 'two words'
    assert_success
    assert_line "TMUX=<unset>"
    assert_line "arg=new-session"
    assert_line "arg=-s"
    assert_line "arg=two words"
}

@test "an empty or missing TMUX_TMPDIR refuses to run tmux (it would use the shared /tmp)" {
    TMUX="/tmp/tmux-1000/default,4242,0" TMUX_TMPDIR="" run "${UNDER_TEST}" ls
    assert_failure
    refute_line --partial "arg=ls"
    run env -u TMUX_TMPDIR TMUX="/tmp/tmux-1000/default,4242,0" "${UNDER_TEST}" ls
    assert_failure
    refute_line --partial "arg=ls"
}
