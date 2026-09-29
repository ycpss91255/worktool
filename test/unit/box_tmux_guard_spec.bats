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
#   packaged binary is moved aside with dpkg-divert, so a later tmux package
#   upgrade lands there and never overwrites the guard.
#
#   The moved-aside real binary is itself a way around the guard (codex
#   round 3 on PR #232): run directly from a box shell entered from a host
#   pane, it still inherits the host TMUX. So (a) it lives OFF PATH, at
#   /usr/libexec/worktool/tmux (no `tmux.real` next to the guard to type or
#   tab-complete), and (b) the box's login shells drop a host TMUX from the
#   environment itself - box/tmux-env.sh (/etc/profile.d, sh / bash) and
#   box/tmux-env.fish (/etc/fish/conf.d, fish) - so nothing started from a
#   box shell, the real binary included, ever sees it.
#
#   box/dev.ini is a plain distrobox-assemble manifest, so the guard and the
#   two shell snippets reach the box as base64 blobs in init hooks. Cases
#   pin that each blob decodes to its readable file byte for byte: the
#   readable file is the one source, the blob can never drift from it.
#
# HOW
#   The guard execs /usr/libexec/worktool/tmux. Each case runs a copy whose exec target
#   is a fake that prints the TMUX / TMUX_TMPDIR it received and its
#   arguments, so what the real tmux would see is asserted directly.
#
# Written test-first: RED with no guard and no install hook in box/dev.ini.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    GUARD="${REPO_ROOT}/box/tmux-guard.sh"
    ENV_SH="${REPO_ROOT}/box/tmux-env.sh"
    ENV_FISH="${REPO_ROOT}/box/tmux-env.fish"
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
    sed "s|/usr/libexec/worktool/tmux|${FAKE}|" "${GUARD}" >"${UNDER_TEST}"
    chmod 0755 "${UNDER_TEST}"
}

@test "box/dev.ini diverts the packaged tmux OFF PATH, to /usr/libexec/worktool/tmux, before installing the guard" {
    local _divert _guard
    _divert="$(grep -nxF 'init_hooks=mkdir -p /usr/libexec/worktool && dpkg-divert --local --rename --divert /usr/libexec/worktool/tmux --add /usr/bin/tmux' "${MANIFEST}")" \
        || fail "no dpkg-divert init hook moving /usr/bin/tmux to /usr/libexec/worktool/tmux"
    _guard="$(grep -nE '^init_hooks=echo .* >/usr/bin/tmux ' "${MANIFEST}")" \
        || fail "no init hook installs the guard at /usr/bin/tmux"
    (( ${_divert%%:*} < ${_guard%%:*} )) || fail "the guard is installed before the divert"
}

@test "the real tmux is never left on PATH: nothing in box/ names /usr/bin/tmux.real (codex round 3)" {
    run grep -rc 'tmux\.real' "${REPO_ROOT}/box" --include='*.ini' --include='*.sh' --include='*.fish'
    refute_output --regexp ':[1-9][0-9]*$'
}

@test "box/dev.ini installs box/tmux-guard.sh, byte for byte, AT /usr/bin/tmux (a path-typed /usr/bin/tmux is guarded too)" {
    local _hook _blob
    _hook="$(grep -E '^init_hooks=echo .* >/usr/bin/tmux ' "${MANIFEST}")"
    [[ "${_hook}" =~ ^init_hooks=echo\ ([A-Za-z0-9+/=]+)\ \|\ base64\ -d\ \>/usr/bin/tmux\ \&\&\ chmod\ 0755\ /usr/bin/tmux$ ]] \
        || fail "unexpected install hook: '${_hook}'"
    _blob="${BASH_REMATCH[1]}"
    assert_equal "$(printf '%s' "${_blob}" | base64 -d | sha256sum)" "$(sha256sum <"${GUARD}")"
}

@test "box/dev.ini no longer relies on PATH order: nothing is installed at /usr/local/bin/tmux" {
    run grep -c '/usr/local/bin/tmux' "${MANIFEST}"
    assert_output "0"
}

@test "the guard execs the diverted real tmux at /usr/libexec/worktool/tmux, not itself" {
    run grep -cE '^exec /usr/libexec/worktool/tmux "\$@"$' "${GUARD}"
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

# --- The box's login shells drop a host TMUX (codex round 3 on PR #232) -----

# Prints the install hook of <file> at <dest> (mode <mode>) from box/dev.ini,
# failing when there is none.
_install_blob() {
    local _dest="$1" _mode="$2" _hook
    _hook="$(grep -F " >${_dest} " "${MANIFEST}")" || return 1
    [[ "${_hook}" =~ ^init_hooks=(mkdir\ -p\ [^ ]+\ \&\&\ )?echo\ ([A-Za-z0-9+/=]+)\ \|\ base64\ -d\ \>([^ ]+)\ \&\&\ chmod\ ([0-7]+)\ ([^ ]+)$ ]] \
        || return 1
    [[ "${BASH_REMATCH[3]}" == "${_dest}" && "${BASH_REMATCH[5]}" == "${_dest}" && "${BASH_REMATCH[4]}" == "${_mode}" ]] \
        || return 1
    printf '%s' "${BASH_REMATCH[2]}"
}

@test "box/dev.ini installs box/tmux-env.sh, byte for byte, at /etc/profile.d/worktool-tmux.sh (sh / bash login shells)" {
    local _blob
    _blob="$(_install_blob /etc/profile.d/worktool-tmux.sh 0644)" \
        || fail "no init hook installs box/tmux-env.sh at /etc/profile.d/worktool-tmux.sh, mode 0644"
    assert_equal "$(printf '%s' "${_blob}" | base64 -d | sha256sum)" "$(sha256sum <"${ENV_SH}")"
}

@test "box/dev.ini installs box/tmux-env.fish, byte for byte, at /etc/fish/conf.d/worktool-tmux.fish (fish)" {
    local _blob
    _blob="$(_install_blob /etc/fish/conf.d/worktool-tmux.fish 0644)" \
        || fail "no init hook installs box/tmux-env.fish at /etc/fish/conf.d/worktool-tmux.fish, mode 0644"
    assert_equal "$(printf '%s' "${_blob}" | base64 -d | sha256sum)" "$(sha256sum <"${ENV_FISH}")"
}

# Sources box/tmux-env.sh in a POSIX sh with the given TMUX / TMUX_TMPDIR
# (`-` = unset), then reports what is left, and that the shell carried on
# with its options untouched.
_source_env_sh() {
    local _tmux="$1" _tmpdir="$2"
    local -a _env=(env -u TMUX -u TMUX_TMPDIR)
    [[ "${_tmux}" == "-" ]] || _env+=("TMUX=${_tmux}")
    [[ "${_tmpdir}" == "-" ]] || _env+=("TMUX_TMPDIR=${_tmpdir}")
    local _probe="${BATS_TEST_TMPDIR}/source-env-probe.sh"
    cat >"${_probe}" <<'EOF'
before="$(set +o)"
. "$1"
printf 'TMUX=%s\n' "${TMUX-<unset>}"
printf 'TMUX_TMPDIR=%s\n' "${TMUX_TMPDIR-<unset>}"
[ "$(set +o)" = "${before}" ] && echo "options=unchanged"
echo "sourced=ok"
EOF
    "${_env[@]}" sh "${_probe}" "${ENV_SH}"
}

@test "tmux-env.sh drops a TMUX naming the HOST server's socket, and returns to the shell" {
    run _source_env_sh "/tmp/tmux-1000/default,4242,0" "${BOX_TMPDIR}"
    assert_success
    assert_line "TMUX=<unset>"
    assert_line "TMUX_TMPDIR=${BOX_TMPDIR}"
    assert_line "options=unchanged"
    assert_line "sourced=ok"
}

@test "tmux-env.sh keeps a TMUX naming the box's own server" {
    local _own="${BOX_TMPDIR}/tmux-1000/default,77,1"
    run _source_env_sh "${_own}" "${BOX_TMPDIR}"
    assert_success
    assert_line "TMUX=${_own}"
    assert_line "sourced=ok"
}

@test "tmux-env.sh drops a socket in a sibling directory that only shares the prefix" {
    run _source_env_sh "${BOX_TMPDIR}-evil/tmux-1000/default,1,0" "${BOX_TMPDIR}"
    assert_success
    assert_line "TMUX=<unset>"
}

@test "tmux-env.sh drops TMUX when TMUX_TMPDIR is empty or unset, without exiting the shell" {
    run _source_env_sh "/tmp/tmux-1000/default,4242,0" ""
    assert_success
    assert_line "TMUX=<unset>"
    assert_line "sourced=ok"
    run _source_env_sh "/tmp/tmux-1000/default,4242,0" "-"
    assert_success
    assert_line "TMUX=<unset>"
    assert_line "sourced=ok"
}

@test "tmux-env.sh with no TMUX at all leaves it unset" {
    run _source_env_sh "-" "${BOX_TMPDIR}"
    assert_success
    assert_line "TMUX=<unset>"
    assert_line "sourced=ok"
}

@test "tmux-env.fish applies the same rule: keeps a TMUX under TMUX_TMPDIR, erases it otherwise" {
    # The test image has no fish; the fish behaviour is proven in the box by
    # test/system/real_engine_spec.bats. Here: the rule's shape.
    run grep -cF "set -l _prefix \"\$TMUX_TMPDIR/\"" "${ENV_FISH}"
    assert_output "1"
    run grep -cF 'set -eg TMUX' "${ENV_FISH}"
    assert_output "1"
}
