#!/usr/bin/env bash
# script/verify/setup.sh - the M3 acceptance items 3.1-3.6, as a script.
#
# doc/acceptance.md item 3 ("進盒設定") used to carry six shell blocks the
# maintainer pasted by hand. Shell logic in a document cannot be linted,
# cannot be tested and cannot be reviewed for the one property that matters
# here: A FAILURE MUST NEVER READ AS A PASS. This script is that logic,
# moved into the repo where the test tier can prove it bites.
#
# Covered items (identical output lines, identical judgements):
#   3.1  dry-run prints the decisions, writes NOTHING, and the managed
#        command names a QUOTED ABSOLUTE distrobox path (#175)
#   3.2  a real write: state file + ghostty managed block, then `status`
#   3.3  --auto-enter no removes the block and reports each removal
#   3.4  bad input is refused by the script, no file is created, and a
#        corrupt state file is refused whatever its source
#   3.5  no distrobox on PATH -> setup refuses and writes nothing;
#        --distrobox <path> names the executable to record
#   3.6  the four remaining states of the `distrobox:` line of `status`
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
# Exit-code-contract script: `set -uo pipefail` (no `-e`), per
# doc/adr/0007; every non-zero exit is explicit.

set -uo pipefail

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

# --- Item registry -----------------------------------------------------------
# Every item belongs to exactly one group, and the group decides what the
# item is allowed to touch:
#
#   temphome  throwaway HOME only; no box, no daemon, nothing installed.
#   realbox   builds the real box on this machine (see the guard below).
#
# All six items of doc/acceptance.md item 3 are `temphome`.
VERIFY_ITEMS=(3.1 3.2 3.3 3.4 3.5 3.6)

_item_group() {
    case "$1" in
        3.1 | 3.2 | 3.3 | 3.4 | 3.5 | 3.6) printf '%s\n' 'temphome' ;;
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

# Normalisation replacements (empty = not applied), so the printed lines
# are the same on every machine whatever the install locations are.
NORM_G=""
NORM_D=""
NORM_H=""

# --- Cleanup -----------------------------------------------------------------
VERIFY_CLEAN_DIRS=()
REALBOX_NAME="dev"
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

Options:
  --allow-real-box  Allow items in group `realbox` (items that build the
                    real box on this machine) to run. Items in group
                    `temphome` - which is all of 3.1-3.6 - never need it.
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
    local _script=()
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
# normalised output, and leave the command's OWN exit status in LAST_RC.
#
# Deliberately not a pipeline: `cmd | norm` reports the status of `norm`,
# and reaching for ${PIPESTATUS[0]} afterwards only moves the problem (a
# `sed` that dies still prints nothing while the run "passes"). Here the
# status is read directly and a failing normaliser fails the check.
_run_norm() {
    local _out="${ITEM_T}/run.out" _nrc
    : >"${_out}" || {
        _fail "cannot write the scratch file ${_out}"
        return 1
    }
    "$@" >"${_out}" 2>&1
    LAST_RC=$?
    _norm <"${_out}"
    _nrc=$?
    if [[ "${_nrc}" -ne 0 ]]; then
        _fail "normalising the output of '$*' failed (exit ${_nrc}); the reported rc cannot be trusted"
        return 1
    fi
    return 0
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
# No item in this file is `realbox` today: 3.1-3.6 all run against a
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
    _list="$(distrobox list)"
    _rc=$?
    [[ "${_rc}" -eq 0 ]] || {
        _fail "cannot tell whether a box named '${REALBOX_NAME}' exists: distrobox list exited ${_rc}"
        return 1
    }
    grep -q -E "(^|[[:space:]])${REALBOX_NAME}([[:space:]]|\$)" <<<"${_list}"
    _rc=$?
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
    mkdir -p -- "${ITEM_H}/.config/ghostty" || {
        _fail "3.1: cannot create ${ITEM_H}/.config/ghostty"
        return 1
    }

    _before="$(_count_files "${ITEM_H}")" || return 1
    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")
    _run_norm "${_env[@]}" just box setup --dry-run || return 1
    printf 'rc=%s\n' "${LAST_RC}"
    _after="$(_count_files "${ITEM_H}")" || return 1
    printf 'files %s->%s\n' "${_before}" "${_after}"

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
    local _g _d _setup_rc _status_rc _ghostty _bad=0
    _g="$(_resolve_exec ghostty 'setup resolves it to log how the terminal default was decided')" || return 1
    _d="$(_resolve_exec distrobox 'setup writes its absolute path into the managed command')" || return 1
    NORM_G="${_g}"
    NORM_D="${_d}"
    mkdir -p -- "${ITEM_H}/.config/ghostty" || {
        _fail "3.2: cannot create ${ITEM_H}/.config/ghostty"
        return 1
    }

    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")
    _run_norm "${_env[@]}" just box setup || return 1
    _setup_rc="${LAST_RC}"
    printf 'rc=%s\n' "${_setup_rc}"
    _run_norm "${_env[@]}" just box status || return 1
    _status_rc="${LAST_RC}"
    printf 'rc=%s\n' "${_status_rc}"

    _ghostty="${ITEM_H}/.config/ghostty/config"
    if [[ -f "${_ghostty}" && -r "${_ghostty}" ]]; then
        _norm <"${_ghostty}" || {
            _fail "3.2: normalising ${_ghostty} failed; its content cannot be judged"
            return 1
        }
    else
        _fail "3.2: setup left no readable ${_ghostty}; there is no managed block to show"
        _bad=1
    fi

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
    local _g _d _blocks _bad=0
    _g="$(_resolve_exec ghostty 'setup resolves it to log how the terminal default was decided')" || return 1
    _d="$(_resolve_exec distrobox 'setup writes its absolute path into the managed command')" || return 1
    NORM_G="${_g}"
    NORM_D="${_d}"
    mkdir -p -- "${ITEM_H}/.config/ghostty" || {
        _fail "3.3: cannot create ${ITEM_H}/.config/ghostty"
        return 1
    }

    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")
    # The removal case has nothing to remove unless the first run wrote a
    # block, so the precondition is checked, not assumed.
    "${_env[@]}" just box setup >/dev/null 2>&1 || {
        _fail "3.3: the first (default) just box setup failed, so there is no managed block to remove"
        return 1
    }
    _run_norm "${_env[@]}" just box setup --auto-enter no || return 1
    printf 'rc=%s\n' "${LAST_RC}"

    _blocks="$(_count_matching 'BEGIN worktool managed block' "${ITEM_H}/.config/ghostty/config")" || return 1
    printf 'blocks=%s\n' "${_blocks}"

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
    _require_tools env just sed find wc mktemp || return 1
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
        printf 'tmux=sideways\ntmux.source=%s\n' "${_src}" \
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
_item_3_5() {
    _require_tools env just sed find wc grep ln mktemp || return 1
    _item_begin || return 1
    local _d _t _p _refuse_rc _files _write_rc _cmd _cmd_norm _grc _bad=0
    _d="$(_resolve_exec distrobox 'the check needs a real one to pass to --distrobox')" || return 1
    _resolve_exec ghostty 'setup must still resolve the terminal under the restricted PATH' >/dev/null || return 1
    # <G> is deliberately NOT normalised here: the expected lines name
    # <H>/bin/ghostty, the copy reached through the restricted PATH.
    NORM_D="${_d}"
    mkdir -p -- "${ITEM_H}/.config/ghostty" "${ITEM_H}/bin" || {
        _fail "3.5: cannot create the throwaway config / bin directories"
        return 1
    }
    # ghostty is linked in next to just, so the terminal detection under
    # the restricted PATH no longer depends on where ghostty is installed.
    for _t in just ghostty; do
        _p="$(_resolve_exec "${_t}" 'the restricted PATH must still hold it')" || return 1
        ln -s "${_p}" "${ITEM_H}/bin/${_t}" || {
            _fail "3.5: cannot link ${_t} into the restricted PATH"
            return 1
        }
    done
    local _path="${ITEM_H}/bin:/usr/bin:/bin"

    local _env=(env "HOME=${ITEM_H}" "XDG_CONFIG_HOME=${ITEM_H}/.config")
    _env+=("PATH=${_path}")
    _run_norm "${_env[@]}" just box setup || return 1
    _refuse_rc="${LAST_RC}"
    printf 'rc=%s\n' "${_refuse_rc}"
    _files="$(_count_files "${ITEM_H}")" || return 1
    printf 'files=%s\n' "${_files}"

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
            if [[ "${_cmd_norm}" != "command = '<D>' enter dev -- tmux new -A -s main" ]]; then
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

    if [[ "${_refuse_rc}" -ne 1 ]]; then
        _fail "3.5: setup with no distrobox on PATH exited ${_refuse_rc}, expected 1"
        _bad=1
    fi
    if [[ "${_files}" -ne 0 ]]; then
        _fail "3.5: the refused run created ${_files} file(s) under the throwaway HOME, expected none"
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
_item_3_6() {
    _require_tools env just sed grep ln chmod mktemp || return 1
    _item_begin || return 1
    local _d _t _p _bad=0
    _d="$(_resolve_exec distrobox 'the on-PATH case reports the one this machine has')" || return 1
    NORM_D="${_d}"
    mkdir -p -- "${ITEM_H}/.config/ghostty" "${ITEM_H}/bin" || {
        _fail "3.6: cannot create the throwaway config / bin directories"
        return 1
    }

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

    # (1) recorded, then moved or removed.
    rm -f -- "${ITEM_H}/bin/distrobox" || {
        _fail "3.6: cannot remove the throwaway distrobox"
        return 1
    }
    _status_distrobox_line || _bad=1

    # (2) an older setup's bare name (this version refuses to write one,
    # so the only way to reach the state is to stage it by hand).
    sed -i "s|^command = .*|command = 'distrobox' enter dev -- tmux new -A -s main|" \
        "${ITEM_H}/.config/ghostty/config" || {
        _fail "3.6: cannot stage the bare-name managed block"
        return 1
    }
    _status_distrobox_line || _bad=1

    # (3) no managed block, but a distrobox on PATH.
    "${_env[@]}" just box setup --auto-enter no >/dev/null 2>&1 || {
        _fail "3.6: setup --auto-enter no failed, so a managed block is still recorded"
        return 1
    }
    _status_distrobox_line || _bad=1

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
    _status_distrobox_line "PATH=${ITEM_H}/bin" || _bad=1

    return "${_bad}"
}

# One 3.6 case: run `status` (with the extra env assignments "$@"), print
# its `distrobox:` line, its own exit status and how many lines it wrote to
# stderr beyond just's recipe echo.
#
# status runs into files rather than into a pipe, so the status reported is
# status's own; the `distrobox:` line must actually be there (a run that
# printed none has nothing to judge, and must not read as a pass).
_status_distrobox_line() {
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

    _stderr="$(_count_not_matching '^\./script/box/status\.sh' "${_err}")" || return 1
    printf 'rc=%s stderr=%s\n' "${_rc}" "${_stderr}"

    local _bad=0
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
