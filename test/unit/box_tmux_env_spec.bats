#!/usr/bin/env bats
# test/unit/box_tmux_env_spec.bats - the box's tmux ENVIRONMENT (issue #179)
#
# WHAT THIS PROVES
#   The box has its own tmux server because box/dev.ini sets TMUX_TMPDIR.
#   But tmux prefers the socket named in $TMUX over TMUX_TMPDIR, and
#   `distrobox enter` copies the caller's whole environment into the box:
#   entered from a HOST tmux pane, the box inherits TMUX (and TMUX_PANE),
#   which names the host server's socket on the /tmp distrobox shares with
#   the host. That is an ENVIRONMENT leak, not a binary one: codex rounds
#   1-4 on PR #232 showed that every wrapper around the tmux binary is
#   bypassed by running the real binary (`distrobox enter dev -- <real
#   tmux>`). So the fix is where the environment is built:
#
#   (1) distrobox-enter itself. It sources distrobox's user config
#       ($XDG_CONFIG_HOME/distrobox/distrobox.conf) as shell BEFORE it
#       copies the environment; `just box setup` keeps a managed block
#       there (lib/enter.sh enter_distrobox_conf_body) that unsets TMUX and
#       TMUX_PANE when the run targets the box. Every `distrobox enter
#       <box>` passes through it - whatever runs after `--`.
#   (2) the box's login shells, as a second line for a run that did not
#       read that config: box/tmux-env.sh (/etc/profile.d, sh / bash) and
#       box/tmux-env.fish (/etc/fish/conf.d) drop a TMUX that does not name
#       a socket under the box's own TMUX_TMPDIR, TMUX_PANE with it.
#
#   And there is no tmux wrapper any more: /usr/bin/tmux in the box is the
#   packaged binary, not moved aside, not replaced.
#
# HOW
#   The two rules are equivalence-class tables. (1) sources the managed
#   line in a POSIX sh with distrobox-enter's argument shapes as "$@" (the
#   file is sourced with the script's own arguments), with TMUX /
#   TMUX_PANE set, and reads what is left. (2) sources box/tmux-env.sh
#   with every class of TMUX x TMUX_TMPDIR. The real distrobox-enter path
#   is proven by test/system/real_enter_env_spec.bats (the pinned
#   distrobox, dry-run) and test/system/real_engine_spec.bats (a real box).
#
# Written test-first: RED against the guard design (tmux-guard.sh, the
# dpkg-divert hooks, no distrobox.conf body in lib/enter.sh).

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    ENV_SH="${REPO_ROOT}/box/tmux-env.sh"
    ENV_FISH="${REPO_ROOT}/box/tmux-env.fish"
    MANIFEST="${REPO_ROOT}/box/dev.ini"
    BOX_TMPDIR="/home/u/dev-box/.cache/tmux"
    HOST_TMUX="/tmp/tmux-1000/default,4242,0"
    # shellcheck source-path=SCRIPTDIR/../../lib
    # shellcheck source=enter.sh
    source "${REPO_ROOT}/lib/enter.sh"
}

# --- no tmux wrapper: the packaged binary stays where it is ------------------

@test "there is no tmux wrapper: no box/tmux-guard.sh, no dpkg-divert, nothing installed at /usr/bin/tmux" {
    assert [ ! -e "${REPO_ROOT}/box/tmux-guard.sh" ]
    run grep -cE 'dpkg-divert|>/usr/bin/tmux|/usr/libexec/worktool|tmux\.real|/usr/local/bin/tmux' "${MANIFEST}"
    assert_output "0"
}

# --- the box's TMUX_TMPDIR: owner and mode enforced, not only on create ----

# `mkdir -p -m 0700` sets the mode only of a directory it creates; an
# existing one keeps a wider mode or another owner (codex rounds 1-4 on
# PR #232). test/system/real_engine_spec.bats restarts a real box over a
# wrong-mode, wrong-owner directory.
@test "the TMUX_TMPDIR hook creates the directory as the box user, then sets its owner and mode 0700 explicitly" {
    # The variables are distrobox-init's, expanded in the box: literal here.
    local _uid="\${container_user_uid}" _gid="\${container_user_gid}" _dir="\${TMUX_TMPDIR}"
    run grep -xF "init_hooks=setpriv --reuid=\"${_uid}\" --regid=\"${_gid}\" --clear-groups mkdir -p -m 0700 \"${_dir}\" && chown \"${_uid}:${_gid}\" \"${_dir}\" && chmod 0700 \"${_dir}\"" "${MANIFEST}"
    assert_success
}

# --- (1) the distrobox.conf line: drops TMUX / TMUX_PANE for the box only ----

# Sources the managed line for box $1 in a POSIX sh under `set -u` (the
# line must be nounset-safe), with the rest of the arguments as "$@" - the
# arguments distrobox-enter was given - and TMUX (TMUX_IN, default the host
# pane's) / TMUX_PANE set. Prints what is left, and whether the positional
# parameters, the shell options and the loop variable are untouched.
_source_conf() {
    local _box="$1"
    shift
    local _conf="${BATS_TEST_TMPDIR}/distrobox.conf"
    enter_distrobox_conf_body "${_box}" >"${_conf}"
    local _probe="${BATS_TEST_TMPDIR}/conf-probe.sh"
    cat >"${_probe}" <<'EOF'
conf="$1"
shift
[ -n "${TMUX}" ] || unset TMUX
set -u
before_opts="$(set +o)"
before_args="$*"
. "${conf}"
printf 'TMUX=%s\n' "${TMUX-<unset>}"
printf 'TMUX_PANE=%s\n' "${TMUX_PANE-<unset>}"
[ "$*" = "${before_args}" ] && echo "args=unchanged"
[ "$(set +o)" = "${before_opts}" ] && echo "options=unchanged"
[ -z "${_worktool_a+x}${_worktool_n+x}${_worktool_v+x}" ] && echo "vars=unset"
EOF
    TMUX="${TMUX_IN-${HOST_TMUX}}" TMUX_PANE="%3" sh "${_probe}" "${_conf}" "$@"
}

@test "the managed line is ONE line, names the box single-quoted, and unsets TMUX and TMUX_PANE" {
    run enter_distrobox_conf_body dev
    assert_success
    assert_equal "${#lines[@]}" 1
    assert_output --partial "'dev'"
    assert_output --partial "unset TMUX TMUX_PANE"
}

# The target box is decided by distrobox-enter's OWN option grammar (pinned
# 1.8.2.5, its `while :; do case $1 in` loop), not by "some token equals
# the box name" (codex round 4 on PR #232):
#   - value-taking options: -n / --name (the box) and -a /
#     --additional-flags (engine flags): their VALUE is never a box name;
#   - every other option is a flag (-v -T -H -r -d -nw -Y --clean-path ...);
#   - every positional argument sets the name, so the LAST one wins;
#   - `--`, `-e`, `--exec` end the options: what follows is the command;
#   - with no name at all, DBX_CONTAINER_NAME (then upstream's default).
# `drop` = the run targets the box, so TMUX and TMUX_PANE must not reach
# it; `keep` = another box, upstream behaviour.
@test "the line targets the box by distrobox-enter's option grammar (value-taking option x value = box x targeted)" {
    local _row _want _got
    local -a _args
    local -a _table=(
        # -n / --name: the value IS the box
        "drop|-n dev"
        "drop|--name dev -- tmux ls"
        "keep|-n other"
        "keep|--name other -- dev"
        # -a / --additional-flags: a value equal to the box name is NOT the box
        "keep|-a dev"
        "keep|-a dev other"
        "keep|--additional-flags dev other -- tmux"
        "drop|-a dev dev"
        "drop|--additional-flags other dev"
        "drop|-a --tty -n dev"
        "keep|-a dev -n other"
        # positionals: the last one wins, after -n too
        "drop|dev"
        "drop|other dev"
        "keep|dev other"
        "keep|-n dev other"
        "drop|-n other dev"
        # flags take no value
        "drop|-nw dev"
        "drop|--no-workdir -T dev"
        "drop|-r -v -d --clean-path -Y -H dev"
        # the separator ends the options
        "drop|dev --"
        "drop|dev -- /usr/bin/tmux new -A -s main"
        "drop|dev -e other"
        "keep|other -- dev"
        "keep|-e dev"
        "keep|--exec dev"
        "keep|--name other --exec -n dev"
        # no name at all
        "keep|"
        "keep|-nw"
        "keep|devx"
    )
    for _row in "${_table[@]}"; do
        _want="${_row%%|*}"
        read -r -a _args <<<"${_row#*|}"
        _got="$(_source_conf dev "${_args[@]}")"
        if [[ "${_want}" == "drop" ]]; then
            [[ "${_got}" == *"TMUX=<unset>"*"TMUX_PANE=<unset>"* ]] \
                || fail "args '${_args[*]}': expected TMUX / TMUX_PANE dropped, got: ${_got}"
        else
            [[ "${_got}" == *"TMUX=${HOST_TMUX}"*"TMUX_PANE=%3"* ]] \
                || fail "args '${_args[*]}': expected TMUX / TMUX_PANE kept, got: ${_got}"
        fi
        [[ "${_got}" == *"args=unchanged"*"options=unchanged"*"vars=unset"* ]] \
            || fail "args '${_args[*]}': the line changed the sourcing shell: ${_got}"
    done
}

@test "DBX_CONTAINER_NAME names the box only when the command line names none" {
    DBX_CONTAINER_NAME=dev run _source_conf dev
    assert_success
    assert_line "TMUX=<unset>"
    assert_line "TMUX_PANE=<unset>"
    DBX_CONTAINER_NAME=dev run _source_conf dev -nw -- tmux
    assert_line "TMUX=<unset>"
    DBX_CONTAINER_NAME=dev run _source_conf dev other
    assert_line "TMUX=${HOST_TMUX}"
    DBX_CONTAINER_NAME=other run _source_conf dev dev
    assert_line "TMUX=<unset>"
    DBX_CONTAINER_NAME=other run _source_conf dev
    assert_line "TMUX=${HOST_TMUX}"
}

@test "the box name is matched literally: a name with a dot does not match any character" {
    run _source_conf 'dev.1' devX1
    assert_line "TMUX=${HOST_TMUX}"
    run _source_conf 'dev.1' dev.1 -- tmux
    assert_line "TMUX=<unset>"
    assert_line "TMUX_PANE=<unset>"
}

@test "with no TMUX in the caller the line is a no-op and does not fail" {
    TMUX_IN="" run _source_conf dev dev
    assert_success
    assert_line "TMUX=<unset>"
    assert_line "args=unchanged"
}

# --- (2) the box's login shells: installed byte for byte ---------------------

# Prints the base64 blob of the install hook of <dest> (mode <mode>) from
# box/dev.ini, failing when there is none.
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

# --- (2) the box's login shells: the keep / drop rule ------------------------

# Sources box/tmux-env.sh in a POSIX sh with the given TMUX / TMUX_TMPDIR
# (`-` = unset, empty = set but empty) and TMUX_PANE=%3, then reports what
# is left, and that the shell carried on with its options untouched.
_source_env_sh() {
    local _tmux="$1" _tmpdir="$2"
    local -a _env=(env -u TMUX -u TMUX_TMPDIR TMUX_PANE=%3)
    [[ "${_tmux}" == "-" ]] || _env+=("TMUX=${_tmux}")
    [[ "${_tmpdir}" == "-" ]] || _env+=("TMUX_TMPDIR=${_tmpdir}")
    local _probe="${BATS_TEST_TMPDIR}/source-env-probe.sh"
    cat >"${_probe}" <<'EOF'
before="$(set +o)"
. "$1"
printf 'TMUX=%s\n' "${TMUX-<unset>}"
printf 'TMUX_PANE=%s\n' "${TMUX_PANE-<unset>}"
printf 'TMUX_TMPDIR=%s\n' "${TMUX_TMPDIR-<unset>}"
[ "$(set +o)" = "${before}" ] && echo "options=unchanged"
echo "sourced=ok"
EOF
    "${_env[@]}" sh "${_probe}" "${ENV_SH}"
}

# TMUX classes x TMUX_TMPDIR classes (`-` = unset). TMUX is kept, and
# TMUX_PANE with it, only when TMUX_TMPDIR is non-empty and TMUX names a
# socket under it.
@test "tmux-env.sh keeps TMUX / TMUX_PANE only for a socket under the box's TMUX_TMPDIR (TMUX x TMUX_TMPDIR table)" {
    local _own="${BOX_TMPDIR}/tmux-1000/default,77,1"
    local _row _want _tmux _tmpdir _got
    local -a _table=(
        "drop|${HOST_TMUX}|${BOX_TMPDIR}"
        "keep|${_own}|${BOX_TMPDIR}"
        "drop|${BOX_TMPDIR}-evil/tmux-1000/default,1,0|${BOX_TMPDIR}"
        "drop|-|${BOX_TMPDIR}"
        "drop|${HOST_TMUX}|"
        "drop|${_own}|"
        "drop|${HOST_TMUX}|-"
        "drop|${_own}|-"
    )
    for _row in "${_table[@]}"; do
        IFS='|' read -r _want _tmux _tmpdir <<<"${_row}"
        _got="$(_source_env_sh "${_tmux}" "${_tmpdir}")"
        if [[ "${_want}" == "keep" ]]; then
            [[ "${_got}" == *"TMUX=${_tmux}"*"TMUX_PANE=%3"* ]] \
                || fail "TMUX='${_tmux}' TMUX_TMPDIR='${_tmpdir}': expected kept, got: ${_got}"
        else
            [[ "${_got}" == *"TMUX=<unset>"*"TMUX_PANE=<unset>"* ]] \
                || fail "TMUX='${_tmux}' TMUX_TMPDIR='${_tmpdir}': expected dropped, got: ${_got}"
        fi
        [[ "${_got}" == *"options=unchanged"*"sourced=ok"* ]] \
            || fail "TMUX='${_tmux}' TMUX_TMPDIR='${_tmpdir}': the snippet changed or ended the shell: ${_got}"
    done
}

@test "tmux-env.fish applies the same rule, TMUX_PANE included" {
    # The test image has no fish; the fish behaviour is proven in the box by
    # test/system/real_engine_spec.bats. Here: the rule's shape.
    run grep -cF "set -l _prefix \"\$TMUX_TMPDIR/\"" "${ENV_FISH}"
    assert_output "1"
    run grep -cE 'set -eg TMUX(_PANE)?$' "${ENV_FISH}"
    assert_output "2"
}
