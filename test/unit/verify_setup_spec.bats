#!/usr/bin/env bats
# test/unit/verify_setup_spec.bats - script/verify/setup.sh (M3 acceptance
# items 3.1-3.9, moved out of doc/acceptance.md)
#
# WHAT THIS PROVES
#   The one property the move exists to buy: A FAILURE CANNOT READ AS A
#   PASS. For every item, the first stage of every pipeline and every
#   external tool the item leans on is replaced with a stub that MISBEHAVES,
#   and the script must exit non-zero. At least one stub per item still
#   prints entirely plausible output and only fails in its EXIT STATUS -
#   that is the exact bug the document's hand-pasted blocks could hide:
#
#     just | sed      -> the pipeline reports sed's 0, the failed just is lost
#     find | wc -l    -> a broken find still answers "0 files", i.e. "clean"
#     grep -c PAT F   -> exit 2 ("cannot read F") prints 0, same as "no match"
#     $(cmd)          -> a plausible string with a non-zero status behind it
#
#   The second family is the one an exit code and a file count cannot see at
#   all: a `just box setup` that RUNS, exits 0 and writes the files it says
#   it writes, while being wrong about WHAT it wrote -
#
#     the managed command names the bare `distrobox` (the #175 regression)
#     a documented decision has stopped being logged
#     the default run writes a ghostty config with no managed block, and the
#       removal run still reports removing one (`blocks=0` either way)
#     the removal resolves a distrobox the document says it does not need
#
#   Every one of those leaves the counts and the statuses exactly as a green
#   run leaves them, so the content assertions are what fail them.
#
#   The third family (round 16) degrades the PRODUCT itself, on a copy of
#   the checkout, and runs that copy's own script/verify/setup.sh. Nothing
#   is stubbed: the output is what the degraded product really prints, and
#   it is self-consistent -
#
#     enter_block_compose writes the whole ghostty config instead of
#       replacing its managed block -> the block is there, `status` says
#       `present`, and the user's configuration has been deleted
#     enter_block_strip empties the file instead of removing the block ->
#       `blocks-before=1`, `blocks=0`, and the same deletion
#
#   Those two are asked of EVERY item that writes or removes a managed
#   block, not only of 3.2 and 3.3 (round 17): 3.5's --distrobox run and
#   3.6's staging write and removal touch the same files, and the managed
#   command, the four `distrobox:` texts and `distinct-states=4/4` are all
#   produced just as happily by a product that deleted the user's config on
#   the way.
#     _report_recorded_distrobox collapses to one branch -> all four of
#       3.6's states answer `runnable`, each with rc=0 and stderr=0
#     _config_write logs the write without writing -> `status` rebuilds the
#       same four decisions from its defaults
#     `_apply_no_terminal` empties the Ghostty config -> the removed block
#       count still passes, but the seeded user content is lost.
#
#   Those are caught by seeding the managed files with the user's own
#   content before setup runs, by reading the state file back, by pinning
#   each of 3.6's four documented texts to the state it belongs to, and by
#   comparing documented lines as WHOLE lines rather than substrings.
#
#   It also proves the environment gate: when ghostty, distrobox or just is
#   not here, the affected item SAYS SO and exits non-zero. Nothing is
#   skipped silently.
#
#   And the group-`realbox` protocol: a real-machine item may not run
#   without the explicit opt-in, may not run when a box named `dev` already
#   exists, and a box this run claimed is removed by the cleanup that the
#   EXIT INT TERM HUP traps share.
#
# HOW
#   Every case runs against a throwaway TMPDIR, and every item the script
#   runs builds its own throwaway HOME under it, so no real configuration
#   is read or written and no box, daemon or package is involved. The image
#   ships no ghostty, so a trivial one is stubbed in for the whole spec;
#   distrobox and just are the real ones the image carries.
#
#   The stubs delegate to the REAL tool (resolved before the stub dir is
#   put on PATH) and then break exactly one thing, so each case pins one
#   guard instead of breaking the run wholesale.
#
#   The first case is the control: with everything behaving, all six items
#   pass. Without it the failure cases below would also be satisfied by a
#   script that can never pass at all.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    VERIFY="${REPO_ROOT}/script/verify/setup.sh"
    STUB="${BATS_TEST_TMPDIR}/stub"
    LINKS="${BATS_TEST_TMPDIR}/links"
    mkdir -p "${STUB}" "${LINKS}"

    # Keep every mktemp -d the script makes inside the case's own tmpdir.
    TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"
    export TMPDIR

    # The real tools, resolved BEFORE the stub directory shadows them, so a
    # stub can still delegate to the genuine article.
    REAL_GREP="$(command -v grep)"
    REAL_SED="$(command -v sed)"
    REAL_FIND="$(command -v find)"
    REAL_MKTEMP="$(command -v mktemp)"
    REAL_JUST="$(command -v just)"

    # No test image ships ghostty; setup.sh only ever runs `command -v` on
    # it, so an executable that does nothing is a faithful stand-in.
    _stub ghostty '#!/bin/sh' 'exit 0'

    # A PATH that holds just and ghostty but NOT distrobox (which the image
    # keeps in /usr/local/bin) - used by the environment-gate cases.
    ln -s "${REAL_JUST}" "${LINKS}/just"
    ln -s "${STUB}/ghostty" "${LINKS}/ghostty"
    NO_DISTROBOX_PATH="${LINKS}:/usr/bin:/bin"

    export PATH="${STUB}:${PATH}"
}

# Write $STUB/$1 from the remaining arguments, one line each, executable.
_stub() {
    local _name="$1"
    shift
    printf '%s\n' "$@" >"${STUB}/${_name}"
    chmod +x "${STUB}/${_name}"
}

# --- The stubs ----------------------------------------------------------------

# A `just` that prints exactly the lines doc/acceptance.md shows and then
# exits $1. Plausible to the eye, wrong in the only place that counts.
_stub_just_plausible() {
    _stub just \
        '#!/bin/sh' \
        'printf "./script/box/setup.sh \"\$@\"\n" >&2' \
        'printf "[INFO] auto-enter: yes (default)\n" >&2' \
        'printf "[INFO] terminal: ghostty (default)\n" >&2' \
        'printf "[INFO] box: dev (default)\n" >&2' \
        'printf "config: /throwaway/.config/worktool/config\n"' \
        'printf "distrobox: /usr/local/bin/distrobox (recorded in a managed block: runnable)\n"' \
        "exit $1"
}

# A `sed` that transforms its input exactly as the real one does and only
# then exits 1: the normalising stage of every printed block.
_stub_sed_output_then_fail() {
    _stub sed \
        '#!/bin/sh' \
        "${REAL_SED} \"\$@\"" \
        'exit 1'
}

# A `find` that answers with a plausible file list and exits 1. Any
# `-type f` call (the file counter) is broken; everything else is real.
_stub_find_list_then_fail() {
    cat >"${STUB}/find" <<EOF
#!/bin/sh
case " \$* " in
  *" -type f "*)
    printf "%s/.config/worktool/config\n" "\$1"
    exit 1
    ;;
esac
exec ${REAL_FIND} "\$@"
EOF
    chmod +x "${STUB}/find"
}

# A `wc` that answers 0 and exits 1: "no files here" with a failure behind it.
_stub_wc_zero_then_fail() {
    _stub wc \
        '#!/bin/sh' \
        'printf "0\n"' \
        'exit 1'
}

# A `grep` whose COUNTING form ($1 = -c or -cv) prints 0 and exits 2 - the
# status that means "I could not read that file", printed as the same 0 a
# clean file gives. Every other grep is the real one.
_stub_grep_count_unreadable() {
    _stub grep \
        '#!/bin/sh' \
        'for a in "$@"; do' \
        "  case \"\$a\" in $1) printf \"0\\n\"; exit 2 ;; esac" \
        'done' \
        "exec ${REAL_GREP} \"\$@\""
}

# A `grep` that prints the managed command line 3.5 expects and exits 1
# ("no match"): the answer looks right, the status says it was never found.
_stub_grep_command_then_no_match() {
    cat >"${STUB}/grep" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    '^command')
      printf "command = 'x' enter dev\n"
      exit 1
      ;;
  esac
done
exec ${REAL_GREP} "\$@"
EOF
    chmod +x "${STUB}/grep"
}

# A `mktemp` that creates and prints a real directory and exits 1.
_stub_mktemp_dir_then_fail() {
    _stub mktemp \
        '#!/bin/sh' \
        "${REAL_MKTEMP} \"\$@\"" \
        'exit 1'
}

# --- The content stubs -------------------------------------------------------
# These two are the shape no exit code and no count can see: a `just box
# setup` that runs, exits 0, writes the files it says it writes, and is
# WRONG ABOUT WHAT IT WROTE. $1 chooses the defect:
#   bare-name  the managed command names `distrobox` instead of the quoted
#              absolute path (the #175 regression)
#   no-block   the default run writes a ghostty config with NO managed block,
#              while the removal run still reports removing one
_stub_just_setup_writing() {
    cat >"${STUB}/just" <<EOF
#!/usr/bin/env bash
# A box setup that behaves correctly everywhere a status code or a file count
# can look, and lies in its text. MODE=$1
set -u
MODE=$1
EOF
    cat >>"${STUB}/just" <<'EOF'
_cfg="${XDG_CONFIG_HOME:-${HOME}/.config}"
_log() { printf '[INFO] %s\n' "$1" >&2; }

case "${1:-}:${2:-}" in
    box:status)
        printf 'config: %s/worktool/config\n' "${_cfg}"
        printf 'auto-enter: yes (default)\n'
        printf 'terminal: ghostty (default)\n'
        printf 'tmux: inside (default)\n'
        printf 'box: dev (default)\n'
        printf 'ghostty: %s/ghostty/config (managed block: present)\n' "${_cfg}"
        printf 'tmux.conf: %s/.tmux.conf (managed block: absent)\n' "${HOME}"
        printf 'distrobox: %s (recorded in a managed block: runnable)\n' \
            "$(command -v distrobox)"
        exit 0
        ;;
    box:setup) ;;
    *) exit 0 ;;
esac

_dbx="$(command -v distrobox)"
case "${MODE}" in
    bare-name) _cmd="command = distrobox enter dev" ;;
    *) _cmd="command = '${_dbx}' enter dev" ;;
esac

_dry=0
_auto=yes
_src=default
shift 2
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) _dry=1 ;;
        --auto-enter)
            shift
            _auto="${1:-yes}"
            _src=user
            ;;
    esac
    shift
done

printf './script/box/setup.sh "$@"\n' >&2
_log "auto-enter: ${_auto} (${_src})"
_log "terminal: ghostty (default)"
_log "terminal detected: ghostty (ghostty executable $(command -v ghostty))"
_log "box: dev (default)"
[ "${_auto}" = yes ] \
    && _log "distrobox: ${_dbx} (absolute path written into the managed command)"

if [ "${_dry}" = 1 ]; then
    _log "dry-run: would write ${_cfg}/worktool/config"
    _log "dry-run: would write ${_cfg}/ghostty/config (managed block: ${_cmd})"
    exit 0
fi

mkdir -p "${_cfg}/worktool" "${_cfg}/ghostty"
printf 'auto-enter=%s\nauto-enter.source=%s\n' "${_auto}" "${_src}" \
    >"${_cfg}/worktool/config"
_log "wrote: ${_cfg}/worktool/config"

if [ "${_auto}" = yes ]; then
    if [ "${MODE}" = no-block ]; then
        # The config is written, and it holds no managed block at all.
        printf 'font-size = 12\n' >"${_cfg}/ghostty/config"
    else
        {
            printf '# BEGIN worktool managed block (just box setup; do not edit)\n'
            printf '%s\n' "${_cmd}"
            printf '# END worktool managed block\n'
        } >"${_cfg}/ghostty/config"
    fi
    _log "wrote: ${_cfg}/ghostty/config (managed block: ${_cmd})"
else
    printf 'font-size = 12\n' >"${_cfg}/ghostty/config"
    _log "removed: ${_cfg}/ghostty/config (managed block: ${_cmd})"
    _log "nothing to remove: ${HOME}/.tmux.conf (no managed block)"
fi
exit 0
EOF
    chmod +x "${STUB}/just"
}

# --- The degraded-product copies ---------------------------------------------
# The stubs above break the TOOLS a check leans on. These break the PRODUCT,
# which is the only way to ask the question round 16 asked: does the check
# still pass when `just box setup` / `just box status` are HONESTLY wrong -
# changed only in the repo's own code, producing output they generate
# themselves and that is self-consistent? Nothing is faked here: a copy of
# the checkout is degraded and ITS script/verify/setup.sh is run, so the
# real tree is never touched and the check has to catch the product on the
# content alone.

# A copy of everything `just box` and `just verify setup` need, under the
# case's own tmpdir.
_repo_copy() {
    local _dst="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${_dst}"
    cp -a "${REPO_ROOT}/justfile" "${REPO_ROOT}/lib" "${REPO_ROOT}/script" \
        "${REPO_ROOT}/box" "${_dst}/"
    printf '%s\n' "${_dst}"
}

# Insert the lines on stdin into file $2 immediately before its first line
# equal to $1, so a later definition of a shell function shadows the one the
# file ships. Pure bash: the image's sed is busybox, and a multi-line `s`
# replacement is not something to depend on here. The result is copied back
# INTO the original file rather than renamed over it, so the script keeps
# its executable bit.
_insert_before() {
    local _anchor="$1" _file="$2" _frag _line _done=0
    _frag="$(cat)"
    : >"${_file}.new"
    while IFS= read -r _line || [ -n "${_line}" ]; do
        if [ "${_done}" -eq 0 ] && [ "${_line}" = "${_anchor}" ]; then
            printf '%s\n' "${_frag}" >>"${_file}.new"
            _done=1
        fi
        printf '%s\n' "${_line}" >>"${_file}.new"
    done <"${_file}"
    [ "${_done}" -eq 1 ] || return 1
    cat "${_file}.new" >"${_file}"
    rm -f "${_file}.new"
}

# Degrade the copy at $1 so that ONLY the tmux-host path overwrites its
# managed file. The ghostty block is still replaced in place, correctly, on
# both tmux placements; ~/.tmux.conf is written over wholesale, and the
# report is exactly the one a correct write prints. This is the regression
# section 3 could not see: 3.1-3.6 never take this branch.
# Degrade the copy at $1 so that ONLY `_apply_no_terminal` - the
# `--terminal none` removal path - empties each managed file instead of
# stripping its block. `_apply_disable` (`--auto-enter no`, the removal
# path 3.3 and 3.7 run) and both write paths are left exactly as they are,
# so the degradation is invisible to every item that does not pass
# `--terminal none`. The log lines are the ones the correct product prints,
# in the same order, naming the same bodies.
_degrade_no_terminal_empties() {
    _insert_before 'setup_run() {' "$1/script/box/setup.sh" <<'EOF'
_apply_no_terminal() {
    local _rc=0 _f _body
    log_info "terminal profile: none (nothing written; enter by hand: distrobox enter ${BOX})"
    for _f in "${GHOSTTY_TARGET}"; do
        enter_block_present "${_f}" || continue
        _body="$(enter_block_body "${_f}")"
        : >"${_f}" || _rc=1
        log_info "removed: ${_f} (managed block: ${_body})"
    done
    return "${_rc}"
}
EOF
}

# Degrade the copy at $1 so that ONLY the `_block_remove` call INSIDE
# `_apply_ghostty` - the one the tmux-INSIDE branch makes, to take out the
# block an earlier `--tmux host` run wrote - empties ~/.tmux.conf instead
# of stripping its block. Every other call site is untouched: the ghostty
# write on both branches, the tmux.conf write on the host branch,
# `_apply_disable` and `_apply_no_terminal` are all exactly as they ship,
# so the degradation is invisible to every item that does not first write
# a ~/.tmux.conf block and then switch back to `--tmux inside`. The log
# line is the one the correct product prints, naming the same body.
# --- Control ------------------------------------------------------------------

@test "control: with every tool behaving, all nine items pass (so the failure cases below are not vacuous)" {
    run "${VERIFY}"
    assert_success
    assert_output --partial "3.1 PASS"
    assert_output --partial "3.2 PASS"
    assert_output --partial "3.3 PASS"
    assert_output --partial "3.4 PASS"
    assert_output --partial "3.5 PASS"
    assert_output --partial "3.6 PASS"
    assert_output --partial "3.7 PASS"
    assert_output --partial "3.8 PASS"
    assert_output --partial "3.9 PASS"
}

# --- CLI ----------------------------------------------------------------------

@test "cli: --help exits 0 and names every item" {
    run "${VERIFY}" --help
    assert_success
    assert_output --partial "Usage: verify/setup.sh"
    assert_output --partial "3.6"
}

@test "cli: an unknown option exits 2 and names the option" {
    run "${VERIFY}" --bogus
    assert_failure 2
    assert_output --partial "verify/setup.sh: unknown option '--bogus' (see --help)"
}

@test "cli: an unknown item exits 2 and names the item" {
    run "${VERIFY}" 9.9
    assert_failure 2
    assert_output --partial "verify/setup.sh: unknown item '9.9' (see --help)"
}

@test "cli: --list prints the nine items with their group" {
    run "${VERIFY}" --list
    assert_success
    assert_line --index 0 --partial "3.1  temphome"
    assert_line --index 5 --partial "3.6  temphome"
    assert_line --index 6 --partial "3.7  temphome"
    assert_line --index 7 --partial "3.8  temphome"
    assert_line --index 8 --partial "3.9  temphome"
    [ "${#lines[@]}" -eq 9 ]
}

# --- 3.1 ----------------------------------------------------------------------

@test "3.1: a just that prints the documented decision lines but exits 1 cannot pass" {
    _stub_just_plausible 1
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.1: a sed that normalises the output correctly but exits 1 cannot pass" {
    _stub_sed_output_then_fail
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "normalising the output"
}

@test "3.1: a find that lists a plausible file but exits 1 cannot pass (the dry-run file count)" {
    _stub_find_list_then_fail
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "counting the files under"
}

@test "3.1: a wc that answers 0 but exits 1 cannot pass (0 files must not mean 0 files)" {
    _stub_wc_zero_then_fail
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "counting the files under"
}

@test "3.1: a dry-run whose managed command names the bare distrobox cannot pass (#175)" {
    # Exit 0, no file written, every decision logged - and the command it says
    # it would write is the bare name the real machine failed on. Only the
    # TEXT of that line tells this run from a correct one.
    _stub_just_setup_writing bare-name
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "enter dev)', found 0"
    refute_output --partial "3.1 PASS"
}

@test "3.1: a dry-run that stops logging one of the documented decisions cannot pass" {
    _stub_just_plausible 0
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "expected exactly one line equal to '[INFO] terminal detected: ghostty (ghostty executable <G>)', found 0"
}

@test "3.1: a mktemp that prints a real directory but exits 1 cannot pass" {
    _stub_mktemp_dir_then_fail
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "mktemp -d failed"
}

@test "3.1: no ghostty on PATH is reported and fails, never skipped" {
    rm -f "${STUB}/ghostty"
    run "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "ghostty is not on PATH"
}

@test "3.1: no distrobox on PATH is reported and fails, never skipped" {
    run env PATH="${NO_DISTROBOX_PATH}" "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "distrobox is not on PATH"
}

@test "3.1: no just on PATH is reported and fails, never skipped" {
    # A PATH holding every tool the check uses EXCEPT just, so the one
    # thing missing is the one the message must name.
    local _d="${BATS_TEST_TMPDIR}/nojust" _t
    mkdir -p "${_d}"
    for _t in env sed find wc mktemp grep ln chmod cat rm mkdir dirname sh bash awk distrobox; do
        ln -s "$(command -v "${_t}")" "${_d}/${_t}"
    done
    ln -s "${STUB}/ghostty" "${_d}/ghostty"
    run env PATH="${_d}" "${VERIFY}" 3.1
    assert_failure
    assert_output --partial "missing on PATH"
    assert_output --partial "just"
}

# --- 3.2 ----------------------------------------------------------------------

@test "3.2: a just that prints the documented write lines but exits 1 cannot pass" {
    _stub_just_plausible 1
    run "${VERIFY}" 3.2
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.2: a just that prints the documented write lines and exits 0 without writing anything cannot pass" {
    _stub_just_plausible 0
    run "${VERIFY}" 3.2
    assert_failure
    assert_output --partial "left no readable"
}

@test "3.2: a setup that writes a managed block naming the bare distrobox cannot pass (#175)" {
    # The file is there, the block is there, `status` says `present`, and
    # every count and exit code is right. The block holds the bare name, and
    # that is the whole of #175 - so the block's CONTENT is what is asserted.
    _stub_just_setup_writing bare-name
    run "${VERIFY}" 3.2
    assert_failure
    assert_output --partial "command = distrobox enter dev"
    assert_output --partial "enter dev', found 0"
    refute_output --partial "3.2 PASS"
}

@test "3.2: a sed that normalises the output correctly but exits 1 cannot pass" {
    _stub_sed_output_then_fail
    run "${VERIFY}" 3.2
    assert_failure
    assert_output --partial "normalising"
}

@test "3.2: a setup that overwrites the whole ghostty config instead of replacing its managed block cannot pass (round 16 gap 1)" {
    # enter_block_compose degraded to "print the block, forget the file".
    # Every count, every exit code, the whole `status` report and the block
    # itself stay exactly as a correct run leaves them - and the ghostty
    # configuration the user came with has been deleted. Only the user
    # content the item seeds BEFORE setup can see it.
    local _repo
    _repo="$(_repo_copy)"
    cat >>"${_repo}/lib/enter.sh" <<'EOF'
enter_block_compose() {
    printf '%s\n%s\n%s\n' "${ENTER_BLOCK_BEGIN}" "$2" "${ENTER_BLOCK_END}"
}
EOF
    run "${_repo}/script/verify/setup.sh" 3.2
    assert_failure
    # The degraded product really did run and really did write the right
    # block; only the user's lines are missing.
    assert_line "[INFO] wrote: <H>/.config/ghostty/config (managed block: command = '<D>' enter dev)"
    assert_line "command = '<D>' enter dev"
    assert_line "ghostty: <H>/.config/ghostty/config (managed block: present)"
    assert_line "user-content after-write: ghostty=LOST tmux.conf=intact"
    assert_output --partial "lost the user's own content"
    refute_output --partial "3.2 PASS"
}

@test "3.2: a setup that logs writing the state file without writing it cannot pass (round 16 gap 3)" {
    # `[INFO] wrote: <H>/.config/worktool/config` is the product's own word
    # for what it did, and `status` prints the same four decisions from its
    # defaults when the file is missing - so the file is read back, and the
    # `config:` line is compared as a WHOLE line (the degraded report's
    # `... (not found - defaults shown ...)` CONTAINS the documented text).
    local _repo
    _repo="$(_repo_copy)"
    _insert_before 'setup_run() {' "${_repo}/script/box/setup.sh" <<'EOF'
_config_write() {
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
        log_info "dry-run: would write ${CONFIG}"
        return 0
    fi
    log_info "wrote: ${CONFIG}"
}
EOF
    run "${_repo}/script/verify/setup.sh" 3.2
    assert_failure
    # setup ran, exited 0 and said it wrote the file; nothing but reading it
    # back can tell that it did not.
    assert_line "[INFO] wrote: <H>/.config/worktool/config"
    assert_line "rc=0"
    assert_output --partial "but left no readable file there"
    assert_output --partial \
        "expected exactly one line equal to 'config: <H>/.config/worktool/config', found 0"
    refute_output --partial "3.2 PASS"
}

# --- 3.3 ----------------------------------------------------------------------

@test "3.3: a just that prints the documented removal lines but exits 1 cannot pass" {
    _stub_just_plausible 1
    run "${VERIFY}" 3.3
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.3: a sed that normalises the output correctly but exits 1 cannot pass" {
    _stub_sed_output_then_fail
    run "${VERIFY}" 3.3
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.3: a config that never held a managed block cannot pass, however convincing the removal report is" {
    # The removal run exits 0, reports the block it removed and the tmux.conf
    # it had nothing to remove from, and leaves blocks=0 - because the first
    # setup never wrote a block. "It is gone" is vacuously true of something
    # that was never there, so the precondition is measured first.
    _stub_just_setup_writing no-block
    run "${VERIFY}" 3.3
    assert_failure
    assert_line "blocks-before=0"
    assert_output --partial "held 0 managed block(s) before the removal"
    refute_output --partial "3.3 PASS"
}

@test "3.3: a removal that resolves a distrobox it does not need cannot pass" {
    # `--auto-enter no` only removes, so the document shows no `distrobox:`
    # decision line for it. This stub logs one anyway.
    cat >"${STUB}/just" <<'EOF'
#!/usr/bin/env bash
set -u
_cfg="${XDG_CONFIG_HOME:-${HOME}/.config}"
_dbx="$(command -v distrobox)"
_cmd="command = '${_dbx}' enter dev"
_log() { printf '[INFO] %s\n' "$1" >&2; }
mkdir -p "${_cfg}/worktool" "${_cfg}/ghostty"
case "$*" in
    *"--auto-enter no"*)
        _log "auto-enter: no (user)"
        _log "terminal: ghostty (default)"
        _log "terminal detected: ghostty (ghostty executable $(command -v ghostty))"
        _log "box: dev (default)"
        _log "distrobox: ${_dbx} (absolute path written into the managed command)"
        printf 'font-size = 12\n' >"${_cfg}/ghostty/config"
        _log "wrote: ${_cfg}/worktool/config"
        _log "removed: ${_cfg}/ghostty/config (managed block: ${_cmd})"
        _log "nothing to remove: ${HOME}/.tmux.conf (no managed block)"
        ;;
    *)
        {
            printf '# BEGIN worktool managed block (just box setup; do not edit)\n'
            printf '%s\n' "${_cmd}"
            printf '# END worktool managed block\n'
        } >"${_cfg}/ghostty/config"
        printf 'auto-enter=yes\n' >"${_cfg}/worktool/config"
        ;;
esac
exit 0
EOF
    chmod +x "${STUB}/just"
    run "${VERIFY}" 3.3
    assert_failure
    assert_line "blocks-before=1"
    assert_output --partial "expected no line containing '[INFO] distrobox:'"
}

@test "3.3: a removal that empties the ghostty config instead of stripping its managed block cannot pass (round 16 gap 1)" {
    # enter_block_strip degraded to "print nothing", so the removal writes an
    # empty file. `blocks-before=1`, `blocks=0`, rc=0 and every removal line
    # are all exactly what a correct removal produces; the user's own lines
    # are what is gone, and they are checked on both sides of the removal so
    # the write is cleared before the removal is blamed.
    local _repo
    _repo="$(_repo_copy)"
    cat >>"${_repo}/lib/enter.sh" <<'EOF'
enter_block_strip() { :; }
EOF
    run "${_repo}/script/verify/setup.sh" 3.3
    assert_failure
    assert_line "user-content after-write: ghostty=intact tmux.conf=intact"
    assert_line "user-content after-removal: ghostty=LOST tmux.conf=intact"
    assert_line "blocks-before=1"
    assert_line "blocks=0"
    refute_output --partial "3.3 PASS"
}

@test "3.3: a grep -c that answers 0 but exits 2 cannot pass (blocks=0 must mean the file was read)" {
    _stub_grep_count_unreadable '-c'
    run "${VERIFY}" 3.3
    assert_failure
    refute_output --partial "3.3 PASS"
}

# --- 3.4 ----------------------------------------------------------------------

@test "3.4: a just that prints the documented refusal but exits 1 instead of 2 cannot pass" {
    _stub_just_plausible 1
    run "${VERIFY}" 3.4
    assert_failure
    assert_output --partial "expected 2"
}

@test "3.4: a just that prints the documented refusal and exits 0 cannot pass (an accepted --bogus is the bug)" {
    _stub_just_plausible 0
    run "${VERIFY}" 3.4
    assert_failure
    assert_output --partial "expected 2"
}

@test "3.4: a sed that normalises the output correctly but exits 1 cannot pass" {
    _stub_sed_output_then_fail
    run "${VERIFY}" 3.4
    assert_failure
    assert_output --partial "normalising the output"
}

@test "3.4: a find that lists a plausible file but exits 1 cannot pass (the created-nothing count)" {
    _stub_find_list_then_fail
    run "${VERIFY}" 3.4
    assert_failure
    assert_output --partial "counting the files under"
}

# --- 3.5 ----------------------------------------------------------------------

@test "3.5: a just that prints the documented restricted-PATH refusal but exits 1 everywhere cannot pass" {
    _stub_just_plausible 1
    run "${VERIFY}" 3.5
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.5: a sed that normalises the output correctly but exits 1 cannot pass" {
    _stub_sed_output_then_fail
    run "${VERIFY}" 3.5
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.5: a grep that prints the expected command line but exits 1 cannot pass" {
    _stub_grep_command_then_no_match
    run "${VERIFY}" 3.5
    assert_failure
    refute_output --partial "3.5 PASS"
}

@test "3.5: a wc that answers 0 but exits 1 cannot pass (the wrote-nothing count)" {
    _stub_wc_zero_then_fail
    run "${VERIFY}" 3.5
    assert_failure
    assert_output --partial "counting the files under"
}

@test "3.5: a --distrobox run that overwrites the whole ghostty config instead of replacing its managed block cannot pass (round 17)" {
    # The same enter_block_compose degradation 3.2 refuses, aimed at the
    # other write in the file. The #175 assertion this item exists for -
    # the managed command names the quoted ABSOLUTE distrobox path - is
    # satisfied word for word by the degraded product, because the command
    # it wrote is right; what it overwrote to write it is the bug.
    local _repo
    _repo="$(_repo_copy)"
    cat >>"${_repo}/lib/enter.sh" <<'EOF'
enter_block_compose() {
    printf '%s\n%s\n%s\n' "${ENTER_BLOCK_BEGIN}" "$2" "${ENTER_BLOCK_END}"
}
EOF
    run "${_repo}/script/verify/setup.sh" 3.5
    assert_failure
    # The refusal half is untouched, and the block really was written.
    assert_line "user-content after-refusal: ghostty=intact tmux.conf=intact"
    assert_line "command = '<D>' enter dev"
    assert_line "user-content after-write: ghostty=LOST tmux.conf=intact"
    assert_output --partial "lost the user's own content"
    refute_output --partial "3.5 PASS"
}

# --- 3.6 ----------------------------------------------------------------------

@test "3.6: a just that prints a plausible distrobox line but exits 1 cannot pass" {
    _stub_just_plausible 1
    run "${VERIFY}" 3.6
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.6: a just that prints a plausible distrobox line and exits 0 without a managed block cannot pass" {
    _stub_just_plausible 0
    run "${VERIFY}" 3.6
    assert_failure
    refute_output --partial "3.6 PASS"
}

@test "3.6: a sed that stages the bare-name block correctly but exits 1 cannot pass" {
    _stub_sed_output_then_fail
    run "${VERIFY}" 3.6
    assert_failure
    assert_output --partial "[FAIL]"
}

@test "3.6: a status.sh whose recorded-distrobox branch always answers runnable cannot pass (round 16 gap 2)" {
    # The four states collapsed into one. Every case still prints a line
    # starting `distrobox:`, still exits 0 and still writes nothing to
    # stderr - which is all the item used to ask for. What it asks for now
    # is the ONE published text each state must produce.
    local _repo
    _repo="$(_repo_copy)"
    _insert_before 'status_run() {' "${_repo}/script/box/status.sh" <<'EOF'
_report_recorded_distrobox() {
    printf 'distrobox: %s (recorded in a managed block: runnable)\n' "$1"
}
EOF
    run "${_repo}/script/verify/setup.sh" 3.6
    assert_failure
    assert_line "distrobox: <H>/bin/distrobox (recorded in a managed block: runnable)"
    assert_output --partial "recorded in a managed block: NOT RUNNABLE"
    refute_output --partial "3.6 PASS"
}

@test "3.6: a staging write that overwrites the whole ghostty config instead of replacing its managed block cannot pass (round 17)" {
    # 3.6 stages its four states with a real `setup --distrobox`. All four
    # documented `distrobox:` texts, all four `rc=0 stderr=0` lines and
    # `distinct-states=4/4` come out exactly as a correct run leaves them -
    # the config the user came with is what is gone.
    local _repo
    _repo="$(_repo_copy)"
    cat >>"${_repo}/lib/enter.sh" <<'EOF'
enter_block_compose() {
    printf '%s\n%s\n%s\n' "${ENTER_BLOCK_BEGIN}" "$2" "${ENTER_BLOCK_END}"
}
EOF
    run "${_repo}/script/verify/setup.sh" 3.6
    assert_failure
    assert_line "user-content after-write: ghostty=LOST tmux.conf=intact"
    # The states themselves were still told apart, so nothing but the user
    # content assertion is failing this run.
    assert_line "distinct-states=4/4"
    assert_output --partial "lost the user's own content"
    refute_output --partial "3.6 PASS"
}

@test "3.6: a removal that empties the ghostty config instead of stripping its managed block cannot pass (round 17)" {
    # The other half: 3.6 reaches its third state with `setup --auto-enter
    # no`. `distrobox: <D> (on PATH; no managed block records one)` is the
    # documented text for "no block recorded" - and an emptied config has
    # no block recorded either, so it answers with the same line.
    local _repo
    _repo="$(_repo_copy)"
    cat >>"${_repo}/lib/enter.sh" <<'EOF'
enter_block_strip() { :; }
EOF
    run "${_repo}/script/verify/setup.sh" 3.6
    assert_failure
    # The write is cleared first, so the removal is what the failure blames.
    assert_line "user-content after-write: ghostty=intact tmux.conf=intact"
    assert_line "user-content after-removal: ghostty=LOST tmux.conf=intact"
    assert_line "distinct-states=4/4"
    refute_output --partial "3.6 PASS"
}

@test "3.6: a grep -cv that answers 0 but exits 2 cannot pass (stderr=0 must mean stderr was read)" {
    _stub_grep_count_unreadable '-cv'
    run "${VERIFY}" 3.6
    assert_failure
    refute_output --partial "3.6 PASS"
}

# --- 3.7 ----------------------------------------------------------------------
@test "3.8: a just that prints a plausible setup but exits 1 cannot pass" {
    _stub_just_plausible 1
    run "${VERIFY}" 3.8
    assert_failure
    assert_output --partial "[FAIL]"
    refute_output --partial "3.8 PASS"
}

@test "3.8: a staging setup that exits 0 without writing the two blocks cannot pass (the removal would be vacuous)" {
    # `--terminal none` removing nothing is indistinguishable from
    # `--terminal none` removing correctly unless the blocks were really
    # there first, so the preconditions are measured and printed.
    _stub_just_plausible 0
    run "${VERIFY}" 3.8
    assert_failure
    assert_line "ghostty-blocks-before=0"
    refute_output --partial "3.8 PASS"
}

@test "3.8: a --terminal none removal that empties the ghostty config instead of stripping their blocks cannot pass (GAP C)" {
    # The degraded product really runs, really reports removing each block
    # by name, and really leaves zero blocks behind: both counts go 1 to 0
    # and `status` calls both files `absent`. It has also just deleted the
    # user's ghostty config AND their ~/.tmux.conf. Only the content seeded
    # before the staging run can see it.
    local _repo
    _repo="$(_repo_copy)"
    _degrade_no_terminal_empties "${_repo}"
    run "${_repo}/script/verify/setup.sh" 3.8
    assert_failure
    assert_line "[INFO] terminal profile: none (nothing written; enter by hand: distrobox enter dev)"
    assert_line "[INFO] removed: <H>/.config/ghostty/config (managed block: command = '<D>' enter dev)"
    assert_line "ghostty-blocks-before=1"
    assert_line "ghostty-blocks=0"
    assert_line "ghostty: <H>/.config/ghostty/config (managed block: absent)"
    # The staging write is cleared first, so the failure is charged to the
    # removal and to nothing else.
    assert_line "user-content after-write: ghostty=intact tmux.conf=intact"
    assert_line "user-content after-removal: ghostty=LOST tmux.conf=intact"
    assert_output --partial "lost the user's own content"
    refute_output --partial "3.8 PASS"
}

@test "3.8 is what catches it: the same degradation leaves every other item of section 3 green" {
    # The honest measure of the gap 3.8 closes. No other item passes
    # `--terminal none` to the product, so they reach `_apply_disable` or
    # the removal inside `_apply_ghostty` instead and this degradation is
    # invisible to all eight of them - which is exactly how a data-losing
    # `_apply_no_terminal` would have reached the maintainer's machine, on
    # the default path of any host without ghostty.
    local _repo
    _repo="$(_repo_copy)"
    _degrade_no_terminal_empties "${_repo}"
    run "${_repo}/script/verify/setup.sh" 3.1 3.2 3.3 3.4 3.5 3.6 3.7
    assert_success
    assert_output --partial "3.3 PASS"
    assert_output --partial "3.7 PASS"
}

@test "3.8: a grep -c that answers 0 but exits 2 cannot pass (the block counts must mean the files were read)" {
    _stub_grep_count_unreadable '-c'
    run "${VERIFY}" 3.8
    assert_failure
    refute_output --partial "3.8 PASS"
}

# --- 3.9 ----------------------------------------------------------------------
# The item that closes the last removal call site that can lose a user file:
@test "realbox: an item in the group is refused without the explicit opt-in" {
    run bash -c "source '${VERIFY}'; _realbox_guard 5.1"
    assert_failure
    assert_output --partial "--allow-real-box"
}

@test "realbox: the opt-in is refused when a box named dev already exists" {
    _stub distrobox '#!/bin/sh' 'printf "NAME  STATUS\ndev   Up 2 hours\n"' 'exit 0'
    run bash -c "source '${VERIFY}'; OPT_ALLOW_REAL_BOX=1; _realbox_guard 5.1"
    assert_failure
    assert_output --partial "already exists"
}

@test "realbox: a distrobox list that prints a plausible list but exits 1 refuses instead of creating anything" {
    _stub distrobox '#!/bin/sh' 'printf "NAME  STATUS\n"' 'exit 1'
    run bash -c "source '${VERIFY}'; OPT_ALLOW_REAL_BOX=1; _realbox_guard 5.1"
    assert_failure
    assert_output --partial "cannot tell whether a box named 'dev' exists"
}

@test "realbox: the opt-in passes when no box named dev exists" {
    _stub distrobox '#!/bin/sh' 'printf "NAME  STATUS\nother  Up\n"' 'exit 0'
    run bash -c "source '${VERIFY}'; OPT_ALLOW_REAL_BOX=1; _realbox_guard 5.1"
    assert_success
}

@test "realbox: a box claimed before creation is removed by the shared cleanup" {
    local _calls="${BATS_TEST_TMPDIR}/distrobox.calls"
    _stub distrobox '#!/bin/sh' "printf '%s\n' \"\$*\" >>'${_calls}'" 'exit 0'
    run bash -c "source '${VERIFY}'; _realbox_claim; _cleanup"
    assert_success
    run cat "${_calls}"
    assert_output --partial "rm --force dev"
}

@test "realbox: a box this run did not claim is never removed" {
    local _calls="${BATS_TEST_TMPDIR}/distrobox.calls"
    _stub distrobox '#!/bin/sh' "printf '%s\n' \"\$*\" >>'${_calls}'" 'exit 0'
    run bash -c "source '${VERIFY}'; _cleanup"
    assert_success
    [ ! -e "${_calls}" ]
}

# --- Cleanup ------------------------------------------------------------------

@test "cleanup: a completed run leaves no throwaway HOME behind" {
    run "${VERIFY}" 3.1
    assert_success
    run "${REAL_FIND}" "${TMPDIR}" -mindepth 1 -maxdepth 1
    assert_output ""
}

@test "3.1: main direct-entry dry-run passes without a tmux decision" {
    run "${VERIFY}" 3.1
    assert_success
    assert_line "[INFO] dry-run: would write <H>/.config/ghostty/config (managed block: command = '<D>' enter dev)"
    refute_output --partial "[INFO] tmux:"
}

@test "3.2: direct-entry state and distrobox isolation are reported" {
    run "${VERIFY}" 3.2
    assert_success
    assert_line "distrobox.conf: <H>/.config/distrobox/distrobox.conf (managed block: present)"
    assert_line "home: not recorded (run: just box assemble)"
    refute_output --partial "tmux: inside"
}

@test "3.3: disabling auto-entry preserves distrobox isolation" {
    run "${VERIFY}" 3.3
    assert_success
    assert_line "blocks-before=1"
    assert_line "blocks=0"
    refute_output --partial "tmux: inside"
}

@test "3.4: corrupted current decision is refused for both sources" {
    run "${VERIFY}" 3.4
    assert_success
    assert_output --partial "invalid value 'sideways' for terminal"
}

@test "3.5: explicit distrobox path writes direct-entry command" {
    run "${VERIFY}" 3.5
    assert_success
    assert_line "command = '<D>' enter dev"
}

@test "3.7: distrobox isolation block is checked and host tmux config stays untouched" {
    run "${VERIFY}" 3.7
    assert_success
    assert_line "distrobox-blocks=1"
    assert_line "user-content after-write: ghostty=intact tmux.conf=intact"
    refute_output --partial "[INFO] tmux:"
}

@test "3.8: terminal none removes the profile and preserves isolation" {
    run "${VERIFY}" 3.8
    assert_success
    assert_line "ghostty-blocks-before=1"
    assert_line "ghostty-blocks=0"
    assert_line "distrobox.conf: <H>/.config/distrobox/distrobox.conf (managed block: present)"
}

@test "3.9: existing config.ghostty receives the legacy block with user content intact" {
    run "${VERIFY}" 3.9
    assert_success
    assert_line "legacy-blocks=0 target-blocks=1"
    assert_line "ghostty: <H>/.config/ghostty/config.ghostty (managed block: present)"
}

@test "3.4: malformed managed files are refused without writes and reported MALFORMED" {
    run "${VERIFY}" 3.4
    assert_success
    assert_line "malformed-refused=distrobox/distrobox.conf unchanged=yes"
    assert_line "malformed-refused=ghostty/config unchanged=yes"
    assert_line "malformed-refused=ghostty/config.ghostty unchanged=yes"
}

@test "3.4: multiple blocks are refused rather than collapsed" {
    run "${VERIFY}" 3.4
    assert_success
    assert_line "multiple-refused=distrobox/distrobox.conf unchanged=yes"
    assert_line "multiple-refused=ghostty/config unchanged=yes"
    assert_line "multiple-refused=ghostty/config+config.ghostty unchanged=yes"
}

@test "3.9: missing old Ghostty version warning cannot pass" {
    _stub ghostty '#!/bin/sh' 'echo Ghostty 1.2.0'
    local _repo
    _repo="$(_repo_copy)"
    _insert_before 'setup_run() {' "${_repo}/script/box/setup.sh" <<'FRAG'
_ghostty_version_warn() { return 0; }
FRAG
    run "${_repo}/script/verify/setup.sh" 3.9
    assert_failure
    assert_output --partial "[WARN] ghostty 1.2.0 does not read"
}

@test "3.2: setup preserves recorded box HOME and reports user config links" {
    run "${VERIFY}" 3.2
    assert_success
    assert_line "home: <H>/dev-box (default)"
    assert_line "link: <H>/dev-box/.acceptance-user -> <H>/.acceptance-user (linked)"
}
