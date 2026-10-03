#!/usr/bin/env bash
# script/verify/setup.sh - the M3 acceptance items 3.1-3.9, as a script.
#
# doc/acceptance.md item 3 ("進盒設定") used to carry six shell blocks the
# maintainer pasted by hand. Shell logic in a document cannot be linted,
# cannot be tested and cannot be reviewed for the one property that matters
# here: A FAILURE MUST NEVER READ AS A PASS. This script is that logic,
# moved into the repo where the test tier can prove it bites.
#
# Items 3.1-3.6 cover dry-run, direct entry, disable, refusal, explicit
# distrobox and the status states. 3.7 checks distrobox.conf isolation;
# 3.8 checks terminal none; 3.9 checks config.ghostty migration.
#
# Every item runs against a THROWAWAY HOME under its own mktemp directory,
# so the maintainer's real configuration is never read or written, and the
# directory is removed on EXIT INT TERM HUP.
#
# WHAT "NO FALSE PASS" MEANS HERE (the whole point of the move)
#   - No pipeline stands between a command and the exit status this script
#     judges: output is captured to a file and normalised afterwards, so
#     the status reported is always the command's OWN, and a broken `sed`
#     cannot turn a failed run into a passing one.
#   - Every command substitution is status-checked; `mktemp` printing a
#     plausible path while exiting non-zero is a failure, not a HOME.
#   - Every count is distinguishable from its degenerate case: `find | wc`
#     only runs once the directory is known to exist, and `grep -c` treats
#     exit 1 ("zero matches") and exit >= 2 ("could not read the input")
#     as different answers, so `blocks=0` can only mean "the file is there
#     and holds no block".
#   - A check that CANNOT run here (no ghostty, no distrobox, no just) says
#     so on stderr and exits non-zero. Nothing is ever skipped silently.
#   - The CONTENT is judged, not only the status and the counts. An exit
#     code says a command ran and a file count says it wrote; neither can
#     see a setup that regressed to the bare `distrobox` name (#175), a
#     decision that stopped being logged, or a removal that reported a
#     block it never touched. _expect_lines pins each documented line to
#     exactly one WHOLE line - never a substring, so a line that merely
#     CONTAINS the documented text (`config: <H>/... (not found - defaults
#     shown...)`) is a failure, not a match - and 3.3 measures that a block
#     EXISTED before it asserts the block is gone; "removed" is vacuously
#     true of a config that never had one.
#   - The USER's content is judged too. Every managed file a check writes is
#     seeded with recognisable user lines BEFORE setup runs, and after every
#     write, rewrite and removal the file's non-block lines must still be
#     exactly those lines, in that order. Without this, a setup that
#     OVERWROTE the whole ghostty config instead of replacing its managed
#     block in place would leave every count, every status and every
#     assertion about the block itself green - while destroying the
#     configuration the user came with.
#   - Every documented STATE is pinned to the case it belongs to. 3.6 does
#     not ask "is there a `distrobox:` line"; it asks for the one of the
#     four published texts that state must produce, and then that the four
#     cases produced four DIFFERENT texts - a status.sh degraded to a single
#     branch answers all four cases identically and is caught.
#   - A state file the report claims to have written is READ BACK. 3.2
#     compares $XDG_CONFIG_HOME/worktool/config against its documented
#     content, line for line and nothing else: `[INFO] wrote: ...` is the
#     product's own claim, and a `status` run on defaults reproduces the
#     rest of the report whether or not the file is there.
#
# Usage: ./script/verify/setup.sh [--allow-real-box] [ITEM...]
#   ./script/verify/setup.sh            # every item, in order, stop at the first failure
#   ./script/verify/setup.sh 3.2        # one item
#   ./script/verify/setup.sh --list     # the items and their groups
#   ./script/verify/setup.sh --help     # usage
#
# This script owns its option validation: an unknown option or an unknown
# item is refused with `verify/setup.sh: ... (see --help)` on stderr, exit
# 2, before any check runs. Check output goes to STDOUT (it is what the
# maintainer compares against doc/acceptance.md); progress, diagnostics and
# [FAIL] lines go to STDERR.
#
# Exit codes: 0 every requested item passed; 1 an item failed or could not
# be run; 2 usage error.
#
# Expected failures are handled explicitly. The item runner deliberately
# calls each check in a conditional so it can report its own verdict.
set -euo pipefail

# --- Paths -------------------------------------------------------------------
# Resolved before anything else and checked here: a REPO_ROOT that silently
# came out empty would send every `just` call to whatever directory the
# caller happened to be in.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
    printf '[FAIL] cannot resolve the directory this script lives in\n' >&2
    exit 1
}
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)" || {
    printf '[FAIL] cannot resolve the repo root above %s\n' "${SCRIPT_DIR}" >&2
    exit 1
}
[[ -n "${SCRIPT_DIR}" && -n "${REPO_ROOT}" ]] || {
    printf '[FAIL] the script / repo paths resolved to nothing\n' >&2
    exit 1
}

LIB_DIR="${REPO_ROOT}/lib"
# shellcheck source-path=SCRIPTDIR/../../lib
# shellcheck source=manifest.sh
source "${LIB_DIR}/manifest.sh"

# --- Item registry -----------------------------------------------------------
# Every item belongs to exactly one group, and the group decides what the
# item is allowed to touch:
#
#   temphome  throwaway HOME only; no box, no daemon, nothing installed.
#   realbox   builds the real box on this machine (see the guard below).
#
# All nine items of doc/acceptance.md item 3 are `temphome`.
VERIFY_ITEMS=(3.1 3.2 3.3 3.4 3.5 3.6 3.7 3.8 3.9)

_item_group() {
    case "$1" in
        3.1 | 3.2 | 3.3 | 3.4 | 3.5 | 3.6 | 3.7 | 3.8 | 3.9) printf '%s\n' 'temphome' ;;
        *) return 1 ;;
    esac
}

_item_title() {
    case "$1" in
        3.1) printf '%s\n' 'dry-run prints the decisions and writes nothing' ;;
        3.2) printf '%s\n' 'a real write: config + ghostty managed block, then status' ;;
        3.3) printf '%s\n' '--auto-enter no removes the managed block' ;;
        3.4) printf '%s\n' 'bad input is refused and nothing is created' ;;
        3.5) printf '%s\n' 'no distrobox on PATH is refused; --distrobox names one' ;;
        3.6) printf '%s\n' 'the four remaining states of the status distrobox line' ;;
        3.7) printf '%s\n' 'distrobox.conf isolates host TMUX and keeps user content' ;;
        3.8) printf '%s\n' '--terminal none removes the profile and preserves isolation' ;;
        3.9) printf '%s\n' 'existing config.ghostty receives the legacy block without content loss' ;;
        *) return 1 ;;
    esac
}

# --- Option state ------------------------------------------------------------
OPT_ALLOW_REAL_BOX=0

# --- Per-item state ----------------------------------------------------------
# Set by _item_begin; read by the guarded primitives below.
ITEM_T=""  # the item's own mktemp directory (scratch; never counted)
ITEM_H=""  # the throwaway HOME inside it
LAST_RC=0  # the exit status of the last command _run_norm ran
LAST_OUT="" # the normalised text _run_norm last printed, so it can be JUDGED
DISTROBOX_LINES_SEEN=() # 3.6: the `distrobox:` line each case actually got

# Pin the acceptance command independently of the product under test.
# The real setup dry-run guard detects drift without redefining this criterion.
MANAGED_CMD="command = '<repo>/script/box/enter.sh' --distrobox '<D>' --box 'dev'"

# The line `_apply_no_terminal` logs instead of writing a profile (item
# 3.8). The BARE `distrobox` in it is deliberate and is pinned here as
# such: it is a command for the user to type in their own interactive
# shell, not a managed command a desktop session runs, so it is the one
# place #175 does not ask for an absolute path. Pinned as a whole line so a
# product that quietly stopped saying what to do instead is caught.
MANAGED_NONE_HINT="terminal profile: none (nothing written; enter by hand: distrobox enter dev)"

# A literal acceptance criterion, compared with real setup by the control
# run; the suppressed-notice regression proves this expectation bites.
GHOSTTY_RELOAD_HINT="[INFO] Ghostty config changed: a running Ghostty must reload its config (Linux default: Ctrl+Shift+,). Reload is asynchronous; wait until the config takes effect before opening a new window, or start a new Ghostty process first. Keep your existing windows open."

# The markers that delimit the managed block, spelled out here rather than
# sourced from lib/enter.sh: enter.sh is the code under test, so a degraded
# stripper must not get to answer the question "what did the user have?".
VERIFY_BLOCK_BEGIN='# BEGIN worktool managed block (just box setup; do not edit)'
VERIFY_BLOCK_END='# END worktool managed block'

# The user content every managed file is seeded with before setup runs.
# Real ghostty configs and ~/.tmux.conf files are not empty; these stand in
# for whatever the user already had, and they must come out the far side of
# every write, rewrite and removal unchanged and in this order.
GHOSTTY_USER_LINES=(
    '# worktool acceptance: user content that must survive every write'
    'font-size = 13'
    'window-padding-x = 7'
)
TMUX_USER_LINES=(
    '# worktool acceptance: user content that must survive every write'
    'set -g history-limit 12345'
    'set -g mouse on'
)

# The whole documented content of the ONE state file `just box setup` writes
# for the default run, in file order. 3.2 reads the file back and compares
# it against exactly this: the `[INFO] wrote:` line is the product talking
# about itself, and `status` prints the same four decisions from its own
# defaults when the file is missing entirely.
STATE_FILE_LINES=(
    '# worktool state: written by "just box setup" and "just box assemble", read by "just box status"; other lines are kept.'
    'auto-enter=yes'
    'auto-enter.source=default'
    'terminal=ghostty'
    'terminal.source=default'
    'box=dev'
    'box.source=default'
)

# The four `distrobox:` texts doc/acceptance.md publishes for item 3.6, in
# the order the item stages them. `runnable` (the fifth) belongs to 3.2.
DISTROBOX_STATE_MOVED="distrobox: <H>/bin/distrobox (recorded in a managed block: NOT RUNNABLE - moved or removed; re-run: just box setup)"
DISTROBOX_STATE_BARE="distrobox: distrobox (recorded in a managed block: a bare name, not an absolute path - a terminal launched from the desktop may not find it; re-run: just box setup)"
DISTROBOX_STATE_ON_PATH="distrobox: <D> (on PATH; no managed block records one)"
DISTROBOX_STATE_NONE="distrobox: not found on PATH (install distrobox, then re-run: just box setup)"

# Normalisation replacements (empty = not applied), so the printed lines
# are the same on every machine whatever the install locations are.
NORM_G=""
NORM_D=""
NORM_H=""

# --- Cleanup -----------------------------------------------------------------
VERIFY_CLEAN_DIRS=()
REALBOX_NAME="$(manifest_name "${REPO_ROOT}/box/dev.ini")" || exit 1
REALBOX_CREATED=0

_cleanup() {
    local _d
    for _d in ${VERIFY_CLEAN_DIRS[@]+"${VERIFY_CLEAN_DIRS[@]}"}; do
        [[ -n "${_d}" && -d "${_d}" ]] && rm -rf -- "${_d}"
    done
    VERIFY_CLEAN_DIRS=()
    _realbox_release
    return 0
}

# A signal must not leave a throwaway HOME (or a box this run created)
# behind, so every one of them runs the same cleanup and then exits with
# the conventional 128+signal status.
_cleanup_and_exit() {
    _cleanup
    trap - EXIT
    exit "$1"
}

trap '_cleanup' EXIT
trap '_cleanup_and_exit 130' INT
trap '_cleanup_and_exit 143' TERM
trap '_cleanup_and_exit 129' HUP

# --- Diagnostics -------------------------------------------------------------
_fail() {
    printf '[FAIL] %s\n' "$*" >&2
    return 0
}

_note() {
    printf '[verify] %s\n' "$*" >&2
    return 0
}

_usage_error() {
    printf 'verify/setup.sh: %s (see --help)\n' "$1" >&2
    return 0
}

_usage() {
    cat >&2 <<'EOF'
Usage: verify/setup.sh [--allow-real-box] [ITEM...]

Run the M3 acceptance checks of doc/acceptance.md item 3 (auto-enter setup).
With no ITEM every item runs, in order, stopping at the first failure.

Items:
  3.1  dry-run prints the decisions and writes nothing
  3.2  a real write: config + ghostty managed block, then status
  3.3  --auto-enter no removes the managed block
  3.4  bad input is refused and nothing is created
  3.5  no distrobox on PATH is refused; --distrobox names one
  3.6  the four remaining states of the status distrobox line
  3.7  distrobox.conf isolates host TMUX and keeps user content
  3.8  --terminal none removes the profile and preserves isolation
  3.9  existing config.ghostty receives the legacy block without content loss

Options:
  --allow-real-box  Allow items in group `realbox` (items that build the
                    real box on this machine) to run. Items in group
                    `temphome` - which is all of 3.1-3.9 - never need it.
  --list            List the items with their group and exit.
  -h, --help        Show this help and exit.

Exit: 0 all requested items passed, 1 an item failed or could not run,
2 usage error.
EOF
    return 0
}

_list_items() {
    local _i _g _t
    for _i in "${VERIFY_ITEMS[@]}"; do
        _g="$(_item_group "${_i}")" || return 1
        _t="$(_item_title "${_i}")" || return 1
        printf '%s  %-9s %s\n' "${_i}" "${_g}" "${_t}"
    done
    return 0
}

# --- Guarded primitives ------------------------------------------------------

# Refuse to pretend a check ran when the tools it needs are not here.
# Prints every missing name, so one run tells the maintainer everything to
# install instead of one name per attempt.
_require_tools() {
    local _t _missing=()
    for _t in "$@"; do
        command -v -- "${_t}" >/dev/null 2>&1 || _missing+=("${_t}")
    done
    if [[ "${#_missing[@]}" -gt 0 ]]; then
        _fail "cannot run this check here: missing on PATH: ${_missing[*]}"
        return 1
    fi
    return 0
}

# Print the ABSOLUTE path of executable $1, or fail with $2 as the reason.
# `command -v` answering a relative path or a shell built-in is refused:
# the acceptance expectations are about a path a desktop-launched terminal
# can run.
_resolve_exec() {
    local _name="$1" _why="$2" _p
    _p="$(command -v -- "${_name}")" || {
        _fail "${_name} is not on PATH - ${_why}"
        return 1
    }
    [[ "${_p}" == /* ]] || {
        _fail "${_name} resolved to '${_p}', which is not an absolute path - ${_why}"
        return 1
    }
    [[ -x "${_p}" ]] || {
        _fail "${_p} is not executable - ${_why}"
        return 1
    }
    printf '%s\n' "${_p}"
    return 0
}

# Start an item: its own scratch directory, a throwaway HOME inside it, and
# a clean normalisation table. The scratch directory is registered for
# cleanup BEFORE anything is created inside it.
_item_begin() {
    local _t
    _t="$(mktemp -d)" || {
        _fail "mktemp -d failed - no throwaway HOME, so nothing can be checked"
        return 1
    }
    [[ -d "${_t}" ]] || {
        _fail "mktemp -d printed '${_t}', which is not a directory"
        return 1
    }
    VERIFY_CLEAN_DIRS+=("${_t}")
    ITEM_T="${_t}"
    ITEM_H="${_t}/home"
    mkdir -p -- "${ITEM_H}" || {
        _fail "cannot create the throwaway HOME ${ITEM_H}"
        return 1
    }
    NORM_G=""
    NORM_D=""
    NORM_H="${ITEM_H}"
    LAST_RC=0
    return 0
}

# Replace the machine-specific paths with <G> / <D> / <H> so the printed
# lines match doc/acceptance.md wherever ghostty and distrobox are
# installed. Reads stdin, writes stdout.
_norm() {
    local _script=(-e "s|${REPO_ROOT}|<repo>|g")
    [[ -n "${NORM_G}" ]] && _script+=(-e "s|${NORM_G}|<G>|g")
    [[ -n "${NORM_D}" ]] && _script+=(-e "s|${NORM_D}|<D>|g")
    [[ -n "${NORM_H}" ]] && _script+=(-e "s|${NORM_H}|<H>|g")
    if [[ "${#_script[@]}" -eq 0 ]]; then
        cat
        return
    fi
    sed "${_script[@]}"
}

# Run "$@" with stdout and stderr merged into a scratch file, print the
# normalised output, leave the command's OWN exit status in LAST_RC and the
# normalised text in LAST_OUT so the caller can judge WHAT was printed.
#
# Deliberately not a pipeline: `cmd | norm` reports the status of `norm`,
# and reaching for ${PIPESTATUS[0]} afterwards only moves the problem (a
# `sed` that dies still prints nothing while the run "passes"). Here the
# status is read directly and a failing normaliser fails the check.
_run_norm() {
    local _out="${ITEM_T}/run.out" _nrc
    LAST_OUT=""
    : >"${_out}" || {
        _fail "cannot write the scratch file ${_out}"
        return 1
    }
    "$@" >"${_out}" 2>&1
    LAST_RC=$?
    LAST_OUT="$(_norm <"${_out}")"
    _nrc=$?
    if [[ "${_nrc}" -ne 0 ]]; then
        _fail "normalising the output of '$*' failed (exit ${_nrc}); the reported rc cannot be trusted"
        return 1
    fi
    [[ -z "${LAST_OUT}" ]] || printf '%s\n' "${LAST_OUT}"
    return 0
}

# Normalise file $1 into LAST_OUT and print it, the way _run_norm does for a
# command. A file that cannot be read is a failure, never an empty block.
_show_norm_file() {
    local _file="$1" _nrc
    LAST_OUT=""
    [[ -f "${_file}" && -r "${_file}" ]] || {
        _fail "cannot show ${_file}: it is not a readable file"
        return 1
    }
    LAST_OUT="$(_norm <"${_file}")"
    _nrc=$?
    if [[ "${_nrc}" -ne 0 ]]; then
        _fail "normalising ${_file} failed (exit ${_nrc}); its content cannot be judged"
        return 1
    fi
    [[ -z "${LAST_OUT}" ]] || printf '%s\n' "${LAST_OUT}"
    return 0
}

# Every documented line of the block just printed is there, EXACTLY ONCE,
# AS A WHOLE LINE.
#
# This is the assertion an exit code and a file count cannot make. `just box
# setup` exiting 0 having written two files says a command ran; only the text
# says it logged each decision and wrote the managed command #175 requires.
# "Exactly once" rather than "at least once" for the same reason the tier
# checks of gate.sh compare sets: a run that printed a decision twice, or
# logged one file twice under two names, has not made the documented claim.
#
# Whole line rather than substring, because the degraded forms of these
# lines are the documented text PLUS something: `config: <H>/.config/
# worktool/config (not found - defaults shown; run: just box setup)` is the
# report for a state file that was never written, and it contains the line
# that means the opposite. Every expectation below is a complete line of
# doc/acceptance.md, so anchoring costs nothing and closes that hole.
# $1 is the item id used in messages; the rest are literal whole lines.
_expect_lines() {
    local _item="$1"
    shift
    local _pat _line _n _bad=0
    for _pat in "$@"; do
        _n=0
        while IFS= read -r _line; do
            [[ "${_line}" == "${_pat}" ]] && _n=$((_n + 1))
        done <<<"${LAST_OUT}"
        if [[ "${_n}" -ne 1 ]]; then
            _fail "${_item}: expected exactly one line equal to '${_pat}', found ${_n}"
            _bad=1
        fi
    done
    return "${_bad}"
}

# The block just printed is EXACTLY these lines, in this order, and holds
# nothing else. Used where the document publishes a whole file rather than a
# set of lines within a larger report (3.2's state file): "every documented
# line is present" cannot see a tenth line the document never mentioned.
# $1 is the item id, $2 names what is being compared, the rest are the lines.
_expect_only_lines() {
    local _item="$1" _what="$2"
    shift 2
    local _want
    _want="$(printf '%s\n' "$@")"
    [[ "${LAST_OUT}" == "${_want}" ]] && return 0
    _fail "${_item}: ${_what} is not the documented content.
--- expected ($# line(s)) ---
${_want}
--- got ---
${LAST_OUT}
---"
    return 1
}

# No line of the block just printed contains $2. Used where the document
# states an absence as part of the claim (3.3: `--auto-enter no` only
# removes, so it never resolves a distrobox and never logs one).
_refute_line() {
    local _item="$1" _pat="$2" _line _n=0
    while IFS= read -r _line; do
        [[ "${_line}" == *"${_pat}"* ]] && _n=$((_n + 1))
    done <<<"${LAST_OUT}"
    [[ "${_n}" -eq 0 ]] && return 0
    _fail "${_item}: expected no line containing '${_pat}', found ${_n}"
    return 1
}

# --- The user's own content --------------------------------------------------
#
# A managed file belongs to the USER; `just box setup` only rents a block
# inside it. Nothing else in this script can see the difference between
# "replaced the managed block in place" and "overwrote the whole file with
# the managed block": the block is there either way, the counts are the same
# either way, `status` says `present` either way - and the second one has
# just deleted the user's ghostty configuration. So each item that writes
# seeds the file first and asserts afterwards, at every point where the
# product touched it.

# Seed the managed files of the current item with the user content above.
# Called instead of a bare mkdir, BEFORE the first setup run, so the check
# below is about content the product found and had to keep.
_seed_user_content() {
    local _item="$1"
    mkdir -p -- "${ITEM_H}/.config/ghostty" || {
        _fail "${_item}: cannot create ${ITEM_H}/.config/ghostty"
        return 1
    }
    printf '%s\n' "${GHOSTTY_USER_LINES[@]}" >"${ITEM_H}/.config/ghostty/config" || {
        _fail "${_item}: cannot seed the throwaway ghostty config with user content"
        return 1
    }
    printf '%s\n' "${TMUX_USER_LINES[@]}" >"${ITEM_H}/.tmux.conf" || {
        _fail "${_item}: cannot seed the throwaway ~/.tmux.conf with user content"
        return 1
    }
    return 0
}

# Print the lines of file $1 that lie OUTSIDE every managed block.
#
# Deliberately not enter_block_strip: lib/enter.sh is the thing being
# accepted here, and a stripper that empties the file would otherwise get to
# report that the file was empty all along.
_user_lines_of() {
    local _file="$1" _line _skip=0
    [[ -f "${_file}" && -r "${_file}" ]] || {
        _fail "cannot read ${_file} to check the user content survived"
        return 1
    }
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        if [[ "${_line}" == "${VERIFY_BLOCK_BEGIN}" ]]; then
            _skip=1
            continue
        fi
        if [[ "${_line}" == "${VERIFY_BLOCK_END}" ]]; then
            _skip=0
            continue
        fi
        [[ "${_skip}" -eq 1 ]] && continue
        printf '%s\n' "${_line}"
    done <"${_file}"
    return 0
}

# Set USER_CONTENT_STATE to `intact` / `LOST` / `UNREADABLE` for file $4.
# $1 item, $2 when (the point in the sequence), $3 label, $4 file, rest the
# lines the file was seeded with.
USER_CONTENT_STATE=""
_check_user_content() {
    local _item="$1" _when="$2" _label="$3" _file="$4"
    shift 4
    local _want _got
    _want="$(printf '%s\n' "$@")"
    USER_CONTENT_STATE="UNREADABLE"
    _got="$(_user_lines_of "${_file}")" || return 1
    if [[ "${_got}" == "${_want}" ]]; then
        USER_CONTENT_STATE="intact"
        return 0
    fi
    USER_CONTENT_STATE="LOST"
    _fail "${_item}: ${_when}: ${_label} lost the user's own content.
Outside the managed block, ${_file} must still hold exactly the $# seeded
line(s), in this order:
${_want}
--- it holds ---
${_got}
---"
    return 1
}

# Both managed files at one point in the sequence, reported on ONE stdout
# line so the item's printed block shows WHERE the check ran.
_expect_user_content() {
    local _item="$1" _when="$2" _bad=0 _g _t
    _check_user_content "${_item}" "${_when}" ghostty \
        "${ITEM_H}/.config/ghostty/config" "${GHOSTTY_USER_LINES[@]}" || _bad=1
    _g="${USER_CONTENT_STATE}"
    _check_user_content "${_item}" "${_when}" tmux.conf \
        "${ITEM_H}/.tmux.conf" "${TMUX_USER_LINES[@]}" || _bad=1
    _t="${USER_CONTENT_STATE}"
    printf 'user-content %s: ghostty=%s tmux.conf=%s\n' "${_when}" "${_g}" "${_t}"
    return "${_bad}"
}

# Print the number of REGULAR files under directory $1.
#
# `find missing/ | wc -l` prints 0 and exits 0 through the pipe: "nothing
# was created" and "there was nothing to look at" read the same. The
# directory is therefore proven first, `pipefail` carries a broken `find`
# out of the pipe, and the answer must look like a number.
_count_files() {
    local _dir="$1" _n
    [[ -d "${_dir}" ]] || {
        _fail "cannot count files: ${_dir} is not a directory"
        return 1
    }
    _n="$(find "${_dir}" -type f | wc -l)" || {
        _fail "counting the files under ${_dir} failed"
        return 1
    }
    _n="${_n//[[:space:]]/}"
    [[ "${_n}" =~ ^[0-9]+$ ]] || {
        _fail "the file count under ${_dir} came back as '${_n}', which is not a number"
        return 1
    }
    printf '%s\n' "${_n}"
    return 0
}

# Print how many lines of file $2 match ($1), or do not match ($1 with
# _count_not_matching), the pattern.
#
# grep exit 1 is "zero matches" and is an answer; exit >= 2 is "I could not
# read that" and is NOT - without the split, a deleted file also counts 0.
# The file is proven readable first so the message says which it was.
_count_grep() {
    local _flag="$1" _pat="$2" _file="$3" _out _rc
    [[ -f "${_file}" && -r "${_file}" ]] || {
        _fail "cannot count '${_pat}': ${_file} is not a readable file"
        return 1
    }
    _out="$(grep "${_flag}" -e "${_pat}" -- "${_file}")"
    _rc=$?
    [[ "${_rc}" -le 1 ]] || {
        _fail "counting '${_pat}' in ${_file} failed (grep exit ${_rc})"
        return 1
    }
    _out="${_out//[[:space:]]/}"
    [[ "${_out}" =~ ^[0-9]+$ ]] || {
        _fail "the count of '${_pat}' in ${_file} came back as '${_out}', which is not a number"
        return 1
    }
    printf '%s\n' "${_out}"
    return 0
}

_count_matching() { _count_grep -c "$1" "$2"; }
_count_not_matching() { _count_grep -cv "$1" "$2"; }

# Print the normalised form of "$1". Used for the single lines the items
# assert on, where the raw text must be judged as well as shown.
_norm_line() {
    local _n
    _n="$(printf '%s\n' "$1" | _norm)" || {
        _fail "normalising a line failed; it cannot be judged"
        return 1
    }
    printf '%s\n' "${_n}"
    return 0
}

# --- Group `realbox`: the real-machine protocol -------------------------------
#
# No item in this file is `realbox` today: 3.1-3.9 all run against a
# throwaway HOME. The guard is what any real-machine item must pass before
# the dispatcher will run it, and it is enforced by the dispatcher rather
# than by the item, so a new item cannot forget it:
#
#   - the caller must opt in explicitly (--allow-real-box): building the
#     box is never something a bare `./script/verify/setup.sh` does;
#   - a box named `dev` that already exists is the maintainer's. The item
#     refuses instead of adopting - and later deleting - someone's work;
#   - ownership is claimed BEFORE the box can exist (_realbox_claim is
#     called before `distrobox create`, not after), so a run interrupted
#     half way through creation is still cleaned up;
#   - the EXIT INT TERM HUP trap removes only a box THIS run created.
_realbox_guard() {
    local _item="$1" _list _rc
    if [[ "${OPT_ALLOW_REAL_BOX}" -ne 1 ]]; then
        _fail "${_item} is in group realbox: it would build the real '${REALBOX_NAME}' box on this machine. Re-run with --allow-real-box to allow that."
        return 1
    fi
    _require_tools distrobox || return 1
    _rc=0
    _list="$(distrobox list)" || _rc=$?
    [[ "${_rc}" -eq 0 ]] || {
        _fail "cannot tell whether a box named '${REALBOX_NAME}' exists: distrobox list exited ${_rc}"
        return 1
    }
    _rc=0
    grep -q -E "(^|[[:space:]])${REALBOX_NAME}([[:space:]]|\$)" <<<"${_list}" || _rc=$?
    case "${_rc}" in
        0)
            _fail "a box named '${REALBOX_NAME}' already exists on this machine; refusing to touch it. Remove it yourself, then re-run."
            return 1
            ;;
        1) return 0 ;;
        *)
            _fail "cannot read the box list (grep exit ${_rc}); refusing to create anything"
            return 1
            ;;
    esac
}

# Claim ownership of the box BEFORE anything can create it.
_realbox_claim() {
    REALBOX_CREATED=1
    return 0
}

# Remove a box this run created. Called from _cleanup, so it runs on EXIT
# and on INT / TERM / HUP alike; a box we did not create is never touched.
_realbox_release() {
    [[ "${REALBOX_CREATED}" -eq 1 ]] || return 0
    REALBOX_CREATED=0
    command -v -- distrobox >/dev/null 2>&1 || {
        _fail "cannot remove the '${REALBOX_NAME}' box this run created: distrobox is not on PATH"
        return 1
    }
    distrobox rm --force "${REALBOX_NAME}" >/dev/null 2>&1 \
        || _fail "could not remove the '${REALBOX_NAME}' box this run created; remove it by hand"
    return 0
}

# --- 3.1 ---------------------------------------------------------------------
# dry-run prints every decision, writes NOTHING, and the managed command it
# WOULD write names the quoted absolute distrobox path (#175).
_item_3_1() {
    _require_tools env just sed find wc mktemp || return 1
    _item_begin || return 1
    local _g _d _before _after _bad=0
    _g="$(_resolve_exec ghostty 'setup resolves it to log how the terminal default was decided')" || return 1
    _d="$(_resolve_exec distrobox 'setup writes its absolute path into the managed command')" || return 1
    NORM_G="${_g}"
    NORM_D="${_d}"
    # The managed files exist and hold the user's own content before the dry
    # run: "nothing was written" is a claim about a file that was already
    # there, and the file count alone cannot see a dry run that rewrote one.
    _seed_user_content 3.1 || return 1

    _before="$(_count_files "${ITEM_H}")" || return 1
    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")
    _run_norm "${_env[@]}" just box setup --dry-run || return 1
    # Judged BEFORE `rc=` is printed, while LAST_OUT still holds this run's
    # text: every decision the document publishes, and the managed command
    # the dry run says it would write (#175).
    _expect_lines 3.1 \
        '[INFO] auto-enter: yes (default)' \
        '[INFO] terminal: ghostty (default)' \
        '[INFO] terminal detected: ghostty (ghostty executable <G>)' \
        '[INFO] box: dev (default)' \
        '[INFO] distrobox: <D> (absolute path written into the managed command)' \
        '[INFO] dry-run: would write <H>/.config/worktool/config' \
        "[INFO] dry-run: would write <H>/.config/ghostty/config (managed block: ${MANAGED_CMD})" \
        || _bad=1
    printf 'rc=%s\n' "${LAST_RC}"
    _after="$(_count_files "${ITEM_H}")" || return 1
    printf 'files %s->%s\n' "${_before}" "${_after}"
    _expect_user_content 3.1 after-dry-run || _bad=1

    if [[ "${LAST_RC}" -ne 0 ]]; then
        _fail "3.1: just box setup --dry-run exited ${LAST_RC}, expected 0"
        _bad=1
    fi
    if [[ "${_after}" -ne "${_before}" ]]; then
        _fail "3.1: --dry-run changed the file count under the throwaway HOME (${_before} -> ${_after}); a dry run must write nothing"
        _bad=1
    fi
    return "${_bad}"
}

# --- 3.2 ---------------------------------------------------------------------
# The real write: state file plus the ghostty managed block, then the
# `status` report and the managed block itself.
_item_3_2() {
    _require_tools env just sed mktemp || return 1
    _item_begin || return 1
    local _g _d _setup_rc _status_rc _ghostty _state _bad=0
    _g="$(_resolve_exec ghostty 'setup resolves it to log how the terminal default was decided')" || return 1
    _d="$(_resolve_exec distrobox 'setup writes its absolute path into the managed command')" || return 1
    NORM_G="${_g}"
    NORM_D="${_d}"
    # The write lands in files the user already owns, so the check can tell
    # "put a block in it" apart from "replaced it with a block".
    _seed_user_content 3.2 || return 1

    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")
    _run_norm "${_env[@]}" just box setup || return 1
    _expect_lines 3.2 \
        '[INFO] auto-enter: yes (default)' \
        '[INFO] terminal: ghostty (default)' \
        '[INFO] terminal detected: ghostty (ghostty executable <G>)' \
        '[INFO] box: dev (default)' \
        '[INFO] distrobox: <D> (absolute path written into the managed command)' \
        '[INFO] wrote: <H>/.config/worktool/config' \
        "[INFO] wrote: <H>/.config/ghostty/config (managed block: ${MANAGED_CMD})" \
        "${GHOSTTY_RELOAD_HINT}" \
        || _bad=1
    _setup_rc="${LAST_RC}"
    printf 'rc=%s\n' "${_setup_rc}"

    # The state file is READ BACK before `status` is asked about it. Without
    # this the item trusts `[INFO] wrote: ...`, which is the product's own
    # word for what it did; and a `status` run with no state file at all
    # prints the same four decisions from its defaults, so the rest of the
    # report cannot tell the difference either.
    _state="${ITEM_H}/.config/worktool/config"
    if _show_norm_file "${_state}"; then
        _expect_only_lines 3.2 "${_state}" "${STATE_FILE_LINES[@]}" || _bad=1
    else
        _fail "3.2: setup reported writing ${_state}, but left no readable file there"
        _bad=1
    fi

    _run_norm "${_env[@]}" just box status || return 1
    # The document publishes the whole eight-line report, including the last
    # line's verdict on whether the recorded distrobox still runs.
    _expect_lines 3.2 \
        'config: <H>/.config/worktool/config' \
        'auto-enter: yes (default)' \
        'terminal: ghostty (default)' \
        'box: dev (default)' \
        'ghostty: <H>/.config/ghostty/config (managed block: present)' \
        'distrobox.conf: <H>/.config/distrobox/distrobox.conf (managed block: present)' \
        'link: box HOME not recorded - user config not linked yet (run: just box assemble)' \
        'home: not recorded (run: just box assemble)' \
        'distrobox: <D> (recorded in a managed block: runnable)' \
        || _bad=1
    _status_rc="${LAST_RC}"
    printf 'rc=%s\n' "${_status_rc}"

    _ghostty="${ITEM_H}/.config/ghostty/config"
    if _show_norm_file "${_ghostty}"; then
        # The block itself, not merely its presence: the markers that delimit
        # it and the ONE managed command it must hold.
        _expect_lines 3.2 \
            '# BEGIN worktool managed block (just box setup; do not edit)' \
            "${MANAGED_CMD}" \
            '# END worktool managed block' \
            || _bad=1
    else
        _fail "3.2: setup left no readable ${_ghostty}; there is no managed block to show"
        _bad=1
    fi
    # The block went INTO the user's files; it did not replace them.
    _expect_user_content 3.2 after-write || _bad=1

    # Seed assemble's persisted HOME and a linked user-config entry through
    # the shared config API, then ensure setup preserves and reports both.
    mkdir -p "${ITEM_H}/dev-box" || return 1
    printf 'acceptance credential\n' >"${ITEM_H}/.acceptance-user" || return 1
    ln -s "${ITEM_H}/.acceptance-user" "${ITEM_H}/dev-box/.acceptance-user" || return 1
    "${_env[@]}" bash -c "source \"\$1/lib/config.sh\"; config_set home \"\$HOME/dev-box\" home.source default link .acceptance-user" bash "${REPO_ROOT}" || return 1
    _run_norm "${_env[@]}" just box setup || return 1
    [[ "${LAST_RC}" -eq 0 ]] || _bad=1
    _show_norm_file "${_state}" || return 1
    _expect_only_lines 3.2 "${_state}" "${STATE_FILE_LINES[@]}" \
        'home=<H>/dev-box' 'home.source=default' 'link=.acceptance-user' || _bad=1
    _run_norm "${_env[@]}" just box status || return 1
    [[ "${LAST_RC}" -eq 0 ]] || _bad=1
    _expect_lines 3.2 \
        'home: <H>/dev-box (default)' \
        'link: <H>/dev-box/.acceptance-user -> <H>/.acceptance-user (linked)' || _bad=1

    if [[ "${_setup_rc}" -ne 0 ]]; then
        _fail "3.2: just box setup exited ${_setup_rc}, expected 0"
        _bad=1
    fi
    if [[ "${_status_rc}" -ne 0 ]]; then
        _fail "3.2: just box status exited ${_status_rc}, expected 0"
        _bad=1
    fi
    return "${_bad}"
}

# --- 3.3 ---------------------------------------------------------------------
# Back to the host shell: setup first (its output is the 3.2 one and is not
# repeated), then --auto-enter no, which removes the block and reports each
# removal. Afterwards zero managed blocks are left.
_item_3_3() {
    _require_tools env just sed grep mktemp || return 1
    _item_begin || return 1
    local _g _d _blocks _before _bad=0
    _g="$(_resolve_exec ghostty 'setup resolves it to log how the terminal default was decided')" || return 1
    _d="$(_resolve_exec distrobox 'setup writes its absolute path into the managed command')" || return 1
    NORM_G="${_g}"
    NORM_D="${_d}"
    # Removal is where overwriting is most tempting and most destructive:
    # "the block is gone" is also true of a config that was truncated.
    _seed_user_content 3.3 || return 1

    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")
    # The removal case has nothing to remove unless the first run wrote a
    # block, so the precondition is checked, not assumed.
    "${_env[@]}" just box setup >/dev/null 2>&1 || {
        _fail "3.3: the first (default) just box setup failed, so there is no managed block to remove"
        return 1
    }
    _expect_user_content 3.3 after-write || _bad=1
    # "The block was removed" is vacuously true of a config that never had
    # one, so the precondition is MEASURED and printed before the removal
    # runs: without this line, a setup that silently stopped writing the
    # block would satisfy `blocks=0` exactly as a working removal does.
    _before="$(_count_matching 'BEGIN worktool managed block' "${ITEM_H}/.config/ghostty/config")" || return 1
    printf 'blocks-before=%s\n' "${_before}"
    if [[ "${_before}" -ne 1 ]]; then
        _fail "3.3: the ghostty config held ${_before} managed block(s) before the removal, expected 1; 'the block is gone' proves nothing about a block that was never there"
        _bad=1
    fi

    _run_norm "${_env[@]}" just box setup --auto-enter no || return 1
    # Every removal is reported by name, and the removed block is named with
    # the command it held; the tmux.conf line is the "there was nothing to
    # undo" half of the same report.
    _expect_lines 3.3 \
        '[INFO] auto-enter: no (user)' \
        '[INFO] terminal: ghostty (default)' \
        '[INFO] terminal detected: ghostty (ghostty executable <G>)' \
        '[INFO] box: dev (default)' \
        '[INFO] wrote: <H>/.config/worktool/config' \
        "[INFO] removed: <H>/.config/ghostty/config (managed block: ${MANAGED_CMD})" \
        || _bad=1
    # Removing needs no distrobox, so the document shows no `distrobox:`
    # decision line here. An implementation that resolved one anyway would
    # be doing work it must not need.
    _refute_line 3.3 '[INFO] distrobox:' || _bad=1
    printf 'rc=%s\n' "${LAST_RC}"

    _blocks="$(_count_matching 'BEGIN worktool managed block' "${ITEM_H}/.config/ghostty/config")" || return 1
    printf 'blocks=%s\n' "${_blocks}"
    _run_norm "${_env[@]}" just box status || return 1
    _expect_lines 3.3 \
        'distrobox.conf: <H>/.config/distrobox/distrobox.conf (managed block: present)' \
        'ghostty: <H>/.config/ghostty/config (managed block: absent)' || _bad=1
    [[ "${LAST_RC}" -eq 0 ]] || _bad=1
    # `blocks=0` is equally true of a config the removal emptied, so the
    # user's own lines are counted again on the far side of the removal.
    _expect_user_content 3.3 after-removal || _bad=1

    if [[ "${LAST_RC}" -ne 0 ]]; then
        _fail "3.3: just box setup --auto-enter no exited ${LAST_RC}, expected 0"
        _bad=1
    fi
    if [[ "${_blocks}" -ne 0 ]]; then
        _fail "3.3: ${_blocks} managed block(s) left in the ghostty config, expected 0"
        _bad=1
    fi
    return "${_bad}"
}

# --- 3.4 ---------------------------------------------------------------------
# Bad input is refused by the script itself (exit 2) and nothing is created
# under HOME; a corrupt state file is refused whatever source it claims.
_item_3_4() {
    _require_tools env just sed find wc mktemp cp diff || return 1
    _item_begin || return 1
    local _bogus_rc _files _src _status_rc _bad=0

    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")
    _run_norm "${_env[@]}" just box setup --bogus || return 1
    _bogus_rc="${LAST_RC}"
    printf 'rc=%s\n' "${_bogus_rc}"
    _files="$(_count_files "${ITEM_H}")" || return 1
    printf 'files=%s\n' "${_files}"

    mkdir -p -- "${ITEM_H}/.config/worktool" || {
        _fail "3.4: cannot create ${ITEM_H}/.config/worktool"
        return 1
    }
    for _src in default user; do
        printf 'terminal=sideways\nterminal.source=%s\n' "${_src}" \
            >"${ITEM_H}/.config/worktool/config" || {
            _fail "3.4: cannot write the corrupt ${_src}-sourced state file"
            return 1
        }
        _run_norm "${_env[@]}" just box status || return 1
        _status_rc="${LAST_RC}"
        printf 'rc=%s\n' "${_status_rc}"
        if [[ "${_status_rc}" -ne 1 ]]; then
            _fail "3.4: just box status accepted the corrupt ${_src}-sourced state file (exit ${_status_rc}, expected 1)"
            _bad=1
        fi
    done

    # Refusal must leave every file untouched, including the shared state.
    rm -f "${ITEM_H}/.config/worktool/config" || return 1
    local _rel _label
    for _rel in distrobox/distrobox.conf ghostty/config ghostty/config.ghostty; do
        mkdir -p "${ITEM_H}/.config/${_rel%/*}" || return 1
        printf '%s\n' "${VERIFY_BLOCK_BEGIN}" 'user content' >"${ITEM_H}/.config/${_rel}" || return 1
        cp -a "${ITEM_H}" "${ITEM_T}/before" || return 1
        _run_norm "${_env[@]}" just box setup --dry-run || return 1
        [[ "${LAST_RC}" -eq 1 ]] || _bad=1
        _run_norm "${_env[@]}" just box setup || return 1
        [[ "${LAST_RC}" -eq 1 ]] || _bad=1
        diff -r "${ITEM_T}/before" "${ITEM_H}" || _bad=1
        _run_norm "${_env[@]}" just box status || return 1
        [[ "${LAST_RC}" -eq 0 ]] || _bad=1
        _label=ghostty
        [[ "${_rel}" != distrobox/* ]] || _label=distrobox.conf
        _expect_lines 3.4 "${_label}: <H>/.config/${_rel} (managed block: MALFORMED - BEGIN at line 1 has no END; fix or remove the markers, then re-run: just box setup)" || _bad=1
        printf 'malformed-refused=%s unchanged=yes\n' "${_rel}"
        rm -rf "${ITEM_T}/before" || return 1
        rm -f "${ITEM_H}/.config/${_rel}" || return 1
    done

    local _case _file _copy
    for _case in distrobox/distrobox.conf ghostty/config ghostty/config+config.ghostty; do
        _file="${ITEM_H}/.config/${_case%%+*}"
        mkdir -p "${_file%/*}" || return 1
        printf '%s\n%s\n%s\n' "${VERIFY_BLOCK_BEGIN}" '# existing body' "${VERIFY_BLOCK_END}" >"${_file}" || return 1
        if [[ "${_case}" == *+* ]]; then
            cp "${_file}" "${ITEM_H}/.config/ghostty/config.ghostty" || return 1
        else
            _copy="$(cat "${_file}")" || return 1
            printf '%s\n' "${_copy}" >>"${_file}" || return 1
        fi
        cp -a "${ITEM_H}" "${ITEM_T}/before" || return 1
        _run_norm "${_env[@]}" just box setup --dry-run || return 1
        [[ "${LAST_RC}" -eq 1 ]] || _bad=1
        _run_norm "${_env[@]}" just box setup || return 1
        [[ "${LAST_RC}" -eq 1 ]] || _bad=1
        diff -r "${ITEM_T}/before" "${ITEM_H}" || return 1
        if [[ "${_case}" != *+* ]]; then
            _run_norm "${_env[@]}" just box status || return 1
            [[ "${LAST_RC}" -eq 0 && "${LAST_OUT}" == *'managed block: MALFORMED'* ]] || _bad=1
        fi
        printf 'multiple-refused=%s unchanged=yes\n' "${_case}"
        rm -rf "${ITEM_T}/before" || return 1
        rm -f "${_file}" "${ITEM_H}/.config/ghostty/config.ghostty" || return 1
    done

    if [[ "${_bogus_rc}" -ne 2 ]]; then
        _fail "3.4: just box setup --bogus exited ${_bogus_rc}, expected 2 (the script refuses an unknown option)"
        _bad=1
    fi
    if [[ "${_files}" -ne 0 ]]; then
        _fail "3.4: a refused run created ${_files} file(s) under the throwaway HOME, expected none"
        _bad=1
    fi
    return "${_bad}"
}

# --- 3.5 ---------------------------------------------------------------------
# With no distrobox on PATH, setup refuses and writes nothing; --distrobox
# <absolute path> names the executable to record (#175: a terminal launched
# from the desktop cannot find ~/.local/bin, so the managed command must
# never be a bare name).
_require_no_distrobox_on_path() {
    if (PATH="$2"; command -v distrobox >/dev/null 2>&1); then
        _fail "$1: environment unfit: distrobox is still on the restricted PATH"
        return 1
    fi
}

_item_3_5() {
    _require_tools env just sed find wc grep ln mktemp || return 1
    _item_begin || return 1
    local _d _t _p _refuse_rc _before _files _write_rc _cmd _cmd_norm _grc _bad=0
    _d="$(_resolve_exec distrobox 'the check needs a real one to pass to --distrobox')" || return 1
    _resolve_exec ghostty 'setup must still resolve the terminal under the restricted PATH' >/dev/null || return 1
    # <G> is deliberately NOT normalised here: the expected lines name
    # <H>/bin/ghostty, the copy reached through the restricted PATH.
    NORM_D="${_d}"
    mkdir -p -- "${ITEM_H}/bin" || {
        _fail "3.5: cannot create the throwaway bin directory"
        return 1
    }
    # This item writes a managed block too (the --distrobox run), so it owes
    # the same debt 3.1-3.3 pay: the file must belong to the user first.
    # `command = '<D>' ...` is there whether the block was put INTO the
    # config or put THERE INSTEAD OF it, so the block assertion below cannot
    # tell the two apart on its own.
    _seed_user_content 3.5 || return 1
    # Only setup's dependencies are linked; including system directories
    # would also expose a distrobox installed by the package manager.
    for _t in just ghostty sh bash dirname awk grep mkdir mktemp mv rm cat chmod flock; do
        _p="$(_resolve_exec "${_t}" 'the restricted PATH must still hold it')" || return 1
        ln -s "${_p}" "${ITEM_H}/bin/${_t}" || {
            _fail "3.5: cannot link ${_t} into the restricted PATH"
            return 1
        }
    done
    local _path="${ITEM_H}/bin"
    _require_no_distrobox_on_path 3.5 "${_path}" || return 1

    # Counted AFTER the seeding, so "the refusal wrote nothing" is a claim
    # about a HOME that already had the user's two files in it.
    _before="$(_count_files "${ITEM_H}")" || return 1

    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")
    _env+=("PATH=${_path}")
    _run_norm "${_env[@]}" just box setup || return 1
    _refuse_rc="${LAST_RC}"
    printf 'rc=%s\n' "${_refuse_rc}"
    _files="$(_count_files "${ITEM_H}")" || return 1
    printf 'files %s->%s\n' "${_before}" "${_files}"
    # A refusal that rewrote a file it had no business touching keeps the
    # file COUNT identical, so the content is what says it kept its hands off.
    _expect_user_content 3.5 after-refusal || _bad=1

    "${_env[@]}" just box setup --distrobox "${_d}" >/dev/null 2>&1
    _write_rc=$?
    printf 'rc=%s\n' "${_write_rc}"

    local _ghostty="${ITEM_H}/.config/ghostty/config"
    if [[ -f "${_ghostty}" && -r "${_ghostty}" ]]; then
        # The status of `grep` is read before its output is used: piping it
        # straight into the normaliser would hide a grep that found
        # nothing behind sed's own exit 0.
        _cmd="$(grep -e '^command' -- "${_ghostty}")"
        _grc=$?
        if [[ "${_grc}" -eq 0 ]]; then
            _cmd_norm="$(_norm_line "${_cmd}")" || return 1
            printf '%s\n' "${_cmd_norm}"
            if [[ "${_cmd_norm}" != "${MANAGED_CMD}" ]]; then
                _fail "3.5: the managed command is '${_cmd_norm}', not the quoted absolute distrobox path #175 requires"
                _bad=1
            fi
        else
            _fail "3.5: no 'command' line in ${_ghostty} (grep exit ${_grc})"
            _bad=1
        fi
    else
        _fail "3.5: --distrobox left no readable ${_ghostty}"
        _bad=1
    fi
    # The --distrobox run rented a block inside the user's config; it did
    # not replace the config with one.
    _expect_user_content 3.5 after-write || _bad=1

    if [[ "${_refuse_rc}" -ne 1 ]]; then
        _fail "3.5: setup with no distrobox on PATH exited ${_refuse_rc}, expected 1"
        _bad=1
    fi
    if [[ "${_files}" -ne "${_before}" ]]; then
        _fail "3.5: the refused run changed the file count under the throwaway HOME (${_before} -> ${_files}); a refusal must write nothing"
        _bad=1
    fi
    if [[ "${_write_rc}" -ne 0 ]]; then
        _fail "3.5: setup --distrobox exited ${_write_rc}, expected 0"
        _bad=1
    fi
    return "${_bad}"
}

# --- 3.6 ---------------------------------------------------------------------
# The `distrobox:` line of `status` in its four remaining states (#177);
# `runnable` is covered by 3.2. Each case prints the line plus that run's
# own exit status and the number of lines it wrote to stderr - `stderr=0`
# is what proves the restricted-PATH case lost DISTROBOX and not one of
# status's own tools.
#
# Each case names the ONE published text its state must produce. "There is a
# `distrobox:` line, status exited 0 and wrote nothing to stderr" is true of
# a status.sh degraded to a single branch that always answers `runnable` -
# the exact shape #177 exists to prevent - so the four documented texts are
# pinned to the four states, and the item then checks they really were four
# different answers.
_item_3_6() {
    _require_tools env just sed grep ln chmod mktemp || return 1
    _item_begin || return 1
    local _d _t _p _bad=0
    DISTROBOX_LINES_SEEN=()
    _d="$(_resolve_exec distrobox 'the on-PATH case reports the one this machine has')" || return 1
    NORM_D="${_d}"
    mkdir -p -- "${ITEM_H}/bin" || {
        _fail "3.6: cannot create the throwaway bin directory"
        return 1
    }
    # The four states are staged by a real write and a real removal, so this
    # item owes the same debt 3.1-3.3 and 3.5 pay. Every `distrobox:` text
    # below is produced just as happily by a setup that overwrote the whole
    # config and a removal that emptied it.
    _seed_user_content 3.6 || return 1

    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")

    # A distrobox of our own, so "recorded then moved away" can be staged
    # without touching the real one.
    printf '#!/bin/sh\nexit 0\n' >"${ITEM_H}/bin/distrobox" || {
        _fail "3.6: cannot write the throwaway distrobox"
        return 1
    }
    chmod +x "${ITEM_H}/bin/distrobox" || {
        _fail "3.6: cannot make the throwaway distrobox executable"
        return 1
    }
    # Every set-up step is status-checked: a setup that did not write is a
    # different state from the one the case means to report.
    "${_env[@]}" just box setup --distrobox "${ITEM_H}/bin/distrobox" >/dev/null 2>&1 || {
        _fail "3.6: setup --distrobox failed, so no managed block records anything"
        return 1
    }
    _expect_user_content 3.6 after-write || _bad=1

    # (1) recorded, then moved or removed.
    rm -f -- "${ITEM_H}/bin/distrobox" || {
        _fail "3.6: cannot remove the throwaway distrobox"
        return 1
    }
    _status_distrobox_line "${DISTROBOX_STATE_MOVED}" || _bad=1

    # (2) an older setup's bare name (this version refuses to write one,
    # so the only way to reach the state is to stage it by hand).
    sed -i "s|^command = .*|command = 'distrobox' enter dev|" \
        "${ITEM_H}/.config/ghostty/config" || {
        _fail "3.6: cannot stage the bare-name managed block"
        return 1
    }
    _status_distrobox_line "${DISTROBOX_STATE_BARE}" || _bad=1

    # (3) no managed block, but a distrobox on PATH.
    "${_env[@]}" just box setup --auto-enter no >/dev/null 2>&1 || {
        _fail "3.6: setup --auto-enter no failed, so a managed block is still recorded"
        return 1
    }
    # `no managed block records one` is equally true of a config the removal
    # emptied, so the user's lines are counted on the far side of it too.
    _expect_user_content 3.6 after-removal || _bad=1
    _status_distrobox_line "${DISTROBOX_STATE_ON_PATH}" || _bad=1

    # (4) neither: a PATH holding exactly the six tools this status path
    # uses and no distrobox, so the one thing missing is the one under
    # test - and stderr stays empty.
    for _t in just sh bash dirname awk grep; do
        _p="$(_resolve_exec "${_t}" 'status itself needs it under the restricted PATH')" || return 1
        ln -s "${_p}" "${ITEM_H}/bin/${_t}" || {
            _fail "3.6: cannot link ${_t} into the restricted PATH"
            return 1
        }
    done
    _require_no_distrobox_on_path 3.6 "${ITEM_H}/bin" || return 1
    _status_distrobox_line "${DISTROBOX_STATE_NONE}" "PATH=${ITEM_H}/bin" || _bad=1

    _expect_distinct_distrobox_lines || _bad=1
    return "${_bad}"
}

# The four cases answered with four DIFFERENT texts.
#
# Per-case equality already refuses a status.sh with one branch; this is the
# claim the document actually makes - "其餘四種狀態各印一次" - stated where
# it can be read, so a future case added with a copy-pasted expectation is
# caught as well.
_expect_distinct_distrobox_lines() {
    local _n="${#DISTROBOX_LINES_SEEN[@]}" _i _j _distinct=0
    if [[ "${_n}" -ne 4 ]]; then
        _fail "3.6: ${_n} of the four documented distrobox states produced a line, expected 4"
        printf 'distinct-states=%s/4\n' "${_n}"
        return 1
    fi
    for ((_i = 0; _i < _n; _i++)); do
        for ((_j = 0; _j < _i; _j++)); do
            if [[ "${DISTROBOX_LINES_SEEN[_i]}" == "${DISTROBOX_LINES_SEEN[_j]}" ]]; then
                _fail "3.6: case $((_i + 1)) and case $((_j + 1)) printed the SAME line, so the two states are not being told apart: ${DISTROBOX_LINES_SEEN[_i]}"
                _distinct=1
            fi
        done
    done
    if [[ "${_distinct}" -ne 0 ]]; then
        printf 'distinct-states=REPEATED/4\n'
        return 1
    fi
    printf 'distinct-states=4/4\n'
    return 0
}

# One 3.6 case: run `status` (with the extra env assignments "$@" after the
# expected line "$1"), print its `distrobox:` line, its own exit status and
# how many lines it wrote to stderr beyond just's recipe echo.
#
# status runs into files rather than into a pipe, so the status reported is
# status's own; the `distrobox:` line must actually be there (a run that
# printed none has nothing to judge, and must not read as a pass) AND it
# must be the text doc/acceptance.md publishes for THIS state - the whole
# line, not a line that happens to start `distrobox:`.
_status_distrobox_line() {
    local _want="$1"
    shift
    local _out="${ITEM_T}/status.out" _err="${ITEM_T}/status.err"
    local _rc _grc _line _shown _stderr
    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")
    "${_env[@]}" "$@" just box status >"${_out}" 2>"${_err}"
    _rc=$?

    _line="$(grep -e '^distrobox:' -- "${_out}")"
    _grc=$?
    if [[ "${_grc}" -gt 1 ]]; then
        _fail "3.6: cannot read the status output (grep exit ${_grc})"
        return 1
    fi
    if [[ "${_grc}" -eq 1 ]]; then
        _fail "3.6: status printed no 'distrobox:' line (exit ${_rc}); there is nothing to judge"
        return 1
    fi
    _shown="$(_norm_line "${_line}")" || return 1
    printf '%s\n' "${_shown}"
    DISTROBOX_LINES_SEEN+=("${_shown}")

    _stderr="$(_count_not_matching '^\./script/box/status\.sh' "${_err}")" || return 1
    printf 'rc=%s stderr=%s\n' "${_rc}" "${_stderr}"

    local _bad=0
    if [[ "${_shown}" != "${_want}" ]]; then
        _fail "3.6: this state must report
  ${_want}
but status reported
  ${_shown}"
        _bad=1
    fi
    if [[ "${_rc}" -ne 0 ]]; then
        _fail "3.6: status exited ${_rc}, expected 0"
        _bad=1
    fi
    if [[ "${_stderr}" -ne 0 ]]; then
        _fail "3.6: status wrote ${_stderr} unexpected line(s) to stderr; the restricted PATH is missing a tool status itself needs"
        _bad=1
    fi
    return "${_bad}"
}

# --- 3.7 ---------------------------------------------------------------------
# The second managed file now belongs to distrobox, never host tmux.
_item_3_7() {
    _require_tools env just sed grep mktemp sh || return 1
    _item_begin || return 1
    _seed_user_content 3.7 || return 1
    local _conf="${ITEM_H}/.config/distrobox/distrobox.conf" _blocks _bad=0
    mkdir -p "${ITEM_H}/.config/distrobox" || return 1
    printf '# acceptance user config\ncontainer_manager=docker\n' >"${_conf}" || return 1
    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")
    _run_norm "${_env[@]}" just box setup --terminal ghostty || return 1
    [[ "${LAST_RC}" -eq 0 ]] || return 1
    _blocks="$(_count_matching 'BEGIN worktool managed block' "${_conf}")" || return 1
    printf 'distrobox-blocks=%s\n' "${_blocks}"
    [[ "${_blocks}" -eq 1 ]] || _bad=1
    _check_user_content 3.7 after-write distrobox.conf "${_conf}" '# acceptance user config' 'container_manager=docker' || _bad=1
    # The config is sourced by a child shell, not by this checker's source graph.
    local _isolation=". \"\$1\"; printf 'TMUX=%s TMUX_PANE=%s\n' \"\${TMUX-unset}\" \"\${TMUX_PANE-unset}\""
    _run_norm env TMUX=host TMUX_PANE=pane sh -c "${_isolation}" sh "${_conf}" dev || return 1
    _expect_lines 3.7 'TMUX=unset TMUX_PANE=unset' || _bad=1
    [[ "${LAST_RC}" -eq 0 ]] || _bad=1
    _run_norm env TMUX=host TMUX_PANE=pane sh -c "${_isolation}" sh "${_conf}" other || return 1
    _expect_lines 3.7 'TMUX=host TMUX_PANE=pane' || _bad=1
    [[ "${LAST_RC}" -eq 0 ]] || _bad=1
    _expect_user_content 3.7 after-write || _bad=1
    return "${_bad}"
}

# --- 3.8 ---------------------------------------------------------------------
# No terminal: remove the profile, keep the independent box isolation.
_item_3_8() {
    _require_tools env just sed grep mktemp || return 1
    _item_begin || return 1
    _seed_user_content 3.8 || return 1
    NORM_D="$(_resolve_exec distrobox 'staging writes the absolute path')" || return 1
    local _ghostty="${ITEM_H}/.config/ghostty/config" _before _blocks _bad=0
    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")
    "${_env[@]}" just box setup --terminal ghostty >/dev/null 2>&1 || {
        _fail "3.8: staging setup failed; no block to remove"
        return 1
    }
    _expect_user_content 3.8 after-write || _bad=1
    _before="$(_count_matching 'BEGIN worktool managed block' "${_ghostty}")" || return 1
    printf 'ghostty-blocks-before=%s\n' "${_before}"
    [[ "${_before}" -eq 1 ]] || _bad=1
    _run_norm "${_env[@]}" just box setup --terminal none || return 1
    [[ "${LAST_RC}" -eq 0 ]] || _bad=1
    _expect_lines 3.8 \
        '[INFO] terminal: none (user)' \
        '[INFO] wrote: <H>/.config/worktool/config' \
        "[INFO] ${MANAGED_NONE_HINT}" || _bad=1
    _refute_line 3.8 '[INFO] distrobox:' || _bad=1
    _refute_line 3.8 '[INFO] terminal detected:' || _bad=1
    _blocks="$(_count_matching 'BEGIN worktool managed block' "${_ghostty}")" || return 1
    printf 'ghostty-blocks=%s\n' "${_blocks}"
    [[ "${_blocks}" -eq 0 ]] || _bad=1
    _expect_user_content 3.8 after-removal || _bad=1
    _run_norm "${_env[@]}" just box status || return 1
    [[ "${LAST_RC}" -eq 0 ]] || _bad=1
    _expect_lines 3.8 \
        'terminal: none (user)' \
        'ghostty: <H>/.config/ghostty/config (managed block: absent)' \
        'distrobox.conf: <H>/.config/distrobox/distrobox.conf (managed block: present)' || _bad=1
    return "${_bad}"
}

# --- 3.9 ---------------------------------------------------------------------
# Switch to the existing modern file: move the single block, keep both files.
_item_3_9() {
    _require_tools env just sed grep mktemp || return 1
    _item_begin || return 1
    _seed_user_content 3.9 || return 1
    local _legacy="${ITEM_H}/.config/ghostty/config" _target="${ITEM_H}/.config/ghostty/config.ghostty"
    local _before _old _new _bad=0
    NORM_D="$(_resolve_exec distrobox 'the managed command records its absolute path')" || return 1
    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")
    "${_env[@]}" just box setup --terminal ghostty >/dev/null 2>&1 || return 1
    _before="$(_count_matching 'BEGIN worktool managed block' "${_legacy}")" || return 1
    [[ "${_before}" -eq 1 ]] || return 1
    printf 'font-size = 17\n' >"${_target}" || return 1
    _run_norm "${_env[@]}" just box setup --terminal ghostty || return 1
    [[ "${LAST_RC}" -eq 0 ]] || _bad=1
    local _exe _version _major _minor
    if _exe="$(command -v ghostty)" && _version="$("${_exe}" +version 2>/dev/null)"; then
        if [[ "${_version}" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
            _version="${BASH_REMATCH[0]}" _major="${BASH_REMATCH[1]}" _minor="${BASH_REMATCH[2]}"
            if (( 10#${_major} < 1 || (10#${_major} == 1 && 10#${_minor} < 3) )); then
                _expect_lines 3.9 "[WARN] ghostty ${_version} does not read <H>/.config/ghostty/config.ghostty (requires 1.3.0 or newer)" || _bad=1
            fi
        fi
    fi
    _expect_lines 3.9 \
        '[INFO] ghostty config: <H>/.config/ghostty/config.ghostty (config.ghostty exists)' \
        '[INFO] moved: <H>/.config/ghostty/config -> <H>/.config/ghostty/config.ghostty (managed block)' || _bad=1
    _old="$(_count_matching 'BEGIN worktool managed block' "${_legacy}")" || return 1
    _new="$(_count_matching 'BEGIN worktool managed block' "${_target}")" || return 1
    printf 'legacy-blocks=%s target-blocks=%s\n' "${_old}" "${_new}"
    [[ "${_old}" -eq 0 && "${_new}" -eq 1 ]] || _bad=1
    _check_user_content 3.9 after-move config.ghostty "${_target}" 'font-size = 17' || _bad=1
    _expect_user_content 3.9 after-move || _bad=1
    _show_norm_file "${_target}" || return 1
    _expect_lines 3.9 "${MANAGED_CMD}" || _bad=1
    _run_norm "${_env[@]}" just box status || return 1
    [[ "${LAST_RC}" -eq 0 ]] || _bad=1
    _expect_lines 3.9 \
        'ghostty: <H>/.config/ghostty/config.ghostty (managed block: present)' \
        'ghostty: <H>/.config/ghostty/config (managed block: absent)' || _bad=1
    return "${_bad}"
}


# --- Dispatcher ---------------------------------------------------------------
_run_item() {
    local _item="$1" _group _rc
    _group="$(_item_group "${_item}")" || {
        _fail "unknown item '${_item}'"
        return 1
    }
    if [[ "${_group}" == "realbox" ]]; then
        _realbox_guard "${_item}" || return 1
    fi
    local _title
    _title="$(_item_title "${_item}")" || _title="(no title)"
    _note "${_item} (group ${_group}): ${_title}"
    case "${_item}" in
        3.1) _item_3_1 ;;
        3.2) _item_3_2 ;;
        3.3) _item_3_3 ;;
        3.4) _item_3_4 ;;
        3.5) _item_3_5 ;;
        3.6) _item_3_6 ;;
        3.7) _item_3_7 ;;
        3.8) _item_3_8 ;;
        3.9) _item_3_9 ;;
        *)
            _fail "no implementation for item '${_item}'"
            return 1
            ;;
    esac
    _rc=$?
    if [[ "${_rc}" -eq 0 ]]; then
        _note "${_item} PASS"
    else
        _note "${_item} FAIL (exit ${_rc})"
    fi
    return "${_rc}"
}

verify_setup_run() {
    local _items=() _item
    # The whole command line is parsed before any check runs.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                _usage
                return 0
                ;;
            --list)
                _list_items
                return 0
                ;;
            --allow-real-box) OPT_ALLOW_REAL_BOX=1 ;;
            -*)
                _usage_error "unknown option '$1'"
                return 2
                ;;
            *)
                if _item_group "$1" >/dev/null; then
                    _items+=("$1")
                else
                    _usage_error "unknown item '$1'"
                    return 2
                fi
                ;;
        esac
        shift
    done
    [[ "${#_items[@]}" -gt 0 ]] || _items=("${VERIFY_ITEMS[@]}")

    # The checks drive `just`, which must find the repo's justfile.
    cd -- "${REPO_ROOT}" || {
        _fail "cannot enter the repo root ${REPO_ROOT}"
        return 1
    }
    for _item in "${_items[@]}"; do
        _run_item "${_item}" || return 1
    done
    return 0
}

# Guard: only run when executed directly, not when sourced (keeps the file
# importable by test/unit/verify_setup_spec.bats).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    verify_setup_run "$@"
fi
