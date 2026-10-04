#!/usr/bin/env bash
# diagram.sh - the M3 acceptance items about the README draw.io diagrams,
# as a script instead of a copy-pasteable block in doc/acceptance.md.
#
# WHAT IT COVERS
#   4.1  doc/diagram/ holds exactly three *.drawio.svg files; none of them
#        contains a <foreignObject> (GitHub refuses to render draw.io HTML
#        labels); each of them embeds its draw.io source as a
#        content="&lt;mxfile ..." attribute (the SVG is the single source,
#        so it stays editable); README.md references the diagram files on
#        four lines (three images + the one edit-link paragraph); and the
#        flow diagram carries the "host 只需 docker + just" wording
#        (issue #163: the host DOES need docker + just).
#
#   The five lines printed on stdout are byte-for-byte the block
#   doc/acceptance.md shows for 4.1, in the same order:
#
#     svg=3
#     foreignobject=0/3
#     mxfile=3/3
#     readme=4
#     flow-wording=1
#
#   so the maintainer still reads the familiar output. Everything else -
#   progress, the reason for a failure, PASS / FAILED - goes to stderr, so
#   stdout stays exactly that block and can be diffed against the document.
#
# WHY IT EXISTS: A FAILURE MUST NEVER READ AS A PASS
#   The document's block was a chain of greps whose statuses were easy to
#   lose. This script is written so that every way of getting a number
#   wrong is louder than getting it right:
#
#   - No pipelines at all. Every external call is a plain command whose
#     status is read immediately, or a command substitution whose status is
#     captured explicitly (locals are declared
#     before the assignment, never `local x=$(...)`, which would mask it).
#   - grep's three statuses are triaged everywhere: 0 = matched,
#     1 = matched nothing, >= 2 = grep itself failed. Only the first two are
#     answers; the third aborts the item. A read error is never counted as
#     "no match".
#   - Every count carries the population it was taken over
#     (`foreignobject=0/3`), and the denominator is incremented only after a
#     file has actually been scanned. `0/3` (three files read, none dirty)
#     is therefore distinguishable from `0/0` (nothing was read at all),
#     and `0/0` cannot be printed: an empty file set is a hard failure.
#   - Every input is proven usable before it is counted: it exists, is a
#     regular file (a dangling symlink is named as such), is readable and
#     is NON-EMPTY. A check over a missing or empty file would report zero
#     matches, which is not a pass.
#   - grep is proven to work, per file, before its answers are believed:
#     a positive probe that must match (the empty pattern, which matches
#     every line of a non-empty file) and a sentinel probe that must not.
#     A grep that always fails to match would otherwise make
#     `foreignobject=0/3` a false pass; a grep that always matches would
#     make `mxfile=3/3` one. Both are caught here.
#   - grep -c's output is checked to be a number before it is used as one.
#   - The counts are not merely printed: each is compared with the value
#     the document expects, and a mismatch fails the item. The five lines
#     are printed first, so a failing run still shows the whole familiar
#     block plus the reason.
#   - Nothing is ever skipped. When a check cannot run here (grep missing,
#     the checkout is not one, the diagram directory is absent), the script
#     says so on stderr and exits non-zero.
#   - grep is the ONLY external command this script runs; its own location,
#     its usage text and every comparison use shell builtins. The surface
#     where an environment can lie to it is therefore one command wide, and
#     test/unit/verify_diagram_spec.bats stubs exactly that surface.
#
# REAL-MACHINE ITEMS
#   This script declares NO real-machine (realbox) items: 4.1 reads files in
#   a checkout and nothing else. It never creates, enters, touches or
#   removes a box, and it writes nothing anywhere. `--realbox` is accepted
#   only so the verify scripts share one command line; here it enables
#   nothing, and says so.
#
# USAGE
#   ./script/verify/diagram.sh            # every item, in order
#   ./script/verify/diagram.sh 4.1        # one item
#   ./script/verify/diagram.sh --root X   # verify another checkout
#   ./script/verify/diagram.sh --help     # usage
#
#   This script owns its option validation: an unknown option (or an
#   unknown item) is refused with `diagram.sh: ... (see --help)` on stderr
#   and exit 2, before any check runs.
#
# EXIT CODES
#   0  every requested item passed
#   1  an item failed
#   2  the command line was refused; nothing ran
#   3  a required tool is unavailable
#
# Use errexit per doc/adr/0001-scripts-use-errexit.md. Expected non-zero
# statuses are captured explicitly to preserve the exit-code contract.

# shellcheck source-path=SCRIPTDIR/../../lib
set -euo pipefail

# --- Paths -------------------------------------------------------------------
# Resolved with shell builtins only (no `dirname`): grep is the ONE external
# command this script runs, so a broken PATH surfaces as the honest
# "grep is not available here" failure instead of as a mangled path.
_SELF_SRC="${BASH_SOURCE[0]}"
if [[ "${_SELF_SRC}" != */* ]]; then
    _SELF_SRC="./${_SELF_SRC}"
fi
SCRIPT_DIR="$(cd -- "${_SELF_SRC%/*}" && pwd -P)"
SELF_ROOT="$(cd -- "${SCRIPT_DIR:-.}/../.." && pwd -P)"
if [[ -z "${SCRIPT_DIR}" || -z "${SELF_ROOT}" ]]; then
    printf '[ERROR] diagram.sh: cannot resolve its own location from %s\n' \
        "${BASH_SOURCE[0]}" >&2
    exit 1
fi

# A root must hold this script to be a worktool checkout: pointing --root at
# the wrong directory is then a refused command line, not "the diagrams are
# missing".
VERIFY_SELF_REL="script/verify/diagram.sh"

# Sourcing a missing library does NOT abort a script without -e, so the
# status is checked here rather than discovered later as a "command not
# found" in the middle of a check.
# shellcheck source=log.sh
if ! source "${SELF_ROOT}/lib/log.sh"; then
    printf '[ERROR] diagram.sh: cannot source %s/lib/log.sh\n' "${SELF_ROOT}" >&2
    exit 1
fi

# shellcheck source=guard.sh
source "${SELF_ROOT}/lib/guard.sh"

# --- The items this script implements ----------------------------------------
# The order a bare run uses. Every entry needs a branch in _run_item.
VERIFY_ITEMS=(4.1)

# Set by diagram_run; read by the reporting helpers.
VERIFY_ROOT=""
VERIFY_ITEM=""
VERIFY_REALBOX=0

# --- What item 4.1 expects (doc/acceptance.md) -------------------------------
EXPECT_SVG_COUNT=3
EXPECT_FOREIGNOBJECT_HITS=0
EXPECT_README_REFS=4
EXPECT_FLOW_WORDING=1

PAT_FOREIGNOBJECT='<foreignObject'
PAT_MXFILE='content="&lt;mxfile'
PAT_README_REF='doc/diagram/.*\.drawio\.svg'
PAT_FLOW_WORDING='host 只需 docker + just'

# A string no input of this repository can contain; used as grep's negative
# self-test probe.
GREP_SENTINEL='WORKTOOL-VERIFY-SENTINEL-9f3c-MUST-NOT-MATCH'

# --- Usage -------------------------------------------------------------------
# Written with printf rather than a `cat` heredoc so that grep stays the one
# external command this script needs: --help must work even on a PATH that
# carries nothing.
_usage() {
    printf '%s\n' \
        'Usage: diagram.sh [--root <repo>] [--realbox] [ITEM...]' \
        '' \
        'Run the doc/acceptance.md M3 diagram acceptance items against a worktool' \
        'checkout and print the same lines the document shows (on stdout; every' \
        'diagnostic goes to stderr).' \
        '' \
        'Items:' \
        '  4.1   doc/diagram/ holds exactly three .drawio.svg files, none carrying a' \
        '        <foreignObject>, each embedding its draw.io mxfile source; README.md' \
        '        references the diagram files on four lines; the flow diagram carries' \
        '        the "host 只需 docker + just" wording.' \
        '' \
        'With no ITEM every item above runs, in order, and the run stops at the first' \
        'failure.' \
        '' \
        '  --root <repo>  worktool checkout to verify (default: the one this script' \
        '                 lives in).' \
        '  --realbox      Accepted so every verify script shares one command line.' \
        '                 This script declares NO real-machine items - it only reads' \
        '                 files - so the flag enables nothing and creates nothing.' \
        '  -h, --help     Show this help and exit.' \
        '' \
        'Exit: 0 every requested item passed; 1 an item failed; 2 the command line' \
        'was refused, nothing ran; 3 a required tool is unavailable (never skipped silently).' \
        >&2
}

# Refuse the command line: one line on stderr; the caller returns 2 and
# nothing has run.
_usage_error() {
    printf 'diagram.sh: %s (see --help)\n' "$1" >&2
}

# --- Reporting ---------------------------------------------------------------

# Report why the item being run failed. Always returns 1.
_item_error() {
    log_error "${VERIFY_ITEM}: $*"
    return 1
}

# Compare one printed number with what the document expects. Returns 1 and
# names both values on a mismatch.
_expect_eq() {
    local _label="$1" _actual="$2" _expected="$3"
    if [[ "${_actual}" == "${_expected}" ]]; then
        return 0
    fi
    _item_error "${_label}: got '${_actual}', expected '${_expected}'"
    return 1
}

# --- Environment guards ------------------------------------------------------

# True iff external command $1 can be run here. A check that cannot run is
# reported and fails; it is never skipped.
_require_tool() {
    guard_require "$1"
}

# True iff $1 is a directory that can be listed.
_require_dir() {
    if [[ ! -d "$1" ]]; then
        _item_error "$1: not a directory (nothing to check)"
        return 1
    fi
    if [[ ! -x "$1" || ! -r "$1" ]]; then
        _item_error "$1: directory cannot be read"
        return 1
    fi
    return 0
}

# True iff file $1 is usable as INPUT of a count: it exists, is a regular
# file, is readable and is not empty - and grep demonstrably answers
# correctly about it. Without this, "zero matches" would be indistinguishable
# from "there was nothing to match against" or "grep never matches anything".
_require_file() {
    local _f="$1"
    if [[ -L "${_f}" && ! -e "${_f}" ]]; then
        _item_error "${_f}: dangling symlink"
        return 1
    fi
    if [[ ! -e "${_f}" ]]; then
        _item_error "${_f}: does not exist"
        return 1
    fi
    if [[ ! -f "${_f}" ]]; then
        _item_error "${_f}: not a regular file"
        return 1
    fi
    if [[ ! -r "${_f}" ]]; then
        _item_error "${_f}: not readable"
        return 1
    fi
    if [[ ! -s "${_f}" ]]; then
        _item_error "${_f}: is empty (a count over it would report zero, which is not a pass)"
        return 1
    fi
    _grep_selftest "${_f}" || return 1
    return 0
}

# Prove grep answers correctly about file $1 before its answers are used as
# evidence: the empty pattern must match (every line of a non-empty file
# matches it, status 0) and the sentinel must not (status 1). A grep that
# always reports "no match" would turn foreignobject=0/3 into a false pass;
# one that always reports a match would do the same to mxfile=3/3.
_grep_selftest() {
    local _f="$1" _rc=0
    grep -q -e '' -- "${_f}" || _rc=$?
    if [[ "${_rc}" -ne 0 ]]; then
        _item_error "grep exited ${_rc} on the always-matches probe over ${_f}; its answers cannot be trusted"
        return 1
    fi
    _rc=0
    grep -q -e "${GREP_SENTINEL}" -- "${_f}" || _rc=$?
    if [[ "${_rc}" -ne 1 ]]; then
        _item_error "grep exited ${_rc} on the never-matches probe over ${_f}; its answers cannot be trusted"
        return 1
    fi
    return 0
}

# --- Counting ----------------------------------------------------------------

# Files collected by _collect_svgs.
DIAGRAM_SVGS=()

# Collect the *.drawio.svg files of directory $1 into DIAGRAM_SVGS.
#
# The glob is not trusted blindly: nullglob is enabled explicitly and its
# status checked, so a pattern that matches nothing yields an EMPTY array
# instead of the literal pattern; and an empty array is a hard failure,
# because "nothing matched" must never be reported as "zero problems found".
_collect_svgs() {
    local _dir="$1" _had_nullglob=0
    if shopt -q nullglob; then
        _had_nullglob=1
    fi
    if ! shopt -s nullglob; then
        _item_error "cannot enable nullglob; refusing to glob ${_dir}"
        return 1
    fi
    DIAGRAM_SVGS=("${_dir}"/*.drawio.svg)
    if [[ "${_had_nullglob}" -eq 0 ]]; then
        if ! shopt -u nullglob; then
            _item_error "cannot restore nullglob"
            return 1
        fi
    fi
    if [[ "${#DIAGRAM_SVGS[@]}" -eq 0 ]]; then
        _item_error "no .drawio.svg under ${_dir} (nothing to count: a failure, not an empty pass)"
        return 1
    fi
    return 0
}

# Result of the last _scan_files, so the count and the population it was
# taken over travel together.
SCAN_HITS=0
SCAN_SCANNED=0

# Scan every file in $2.. for pattern $1, ONE FILE AT A TIME, and set
# SCAN_HITS / SCAN_SCANNED.
#
# grep's status is triaged per file: 0 = this file matches, 1 = it does not,
# anything else = grep itself failed, which aborts the whole scan instead of
# being silently counted as "no match". SCAN_SCANNED is incremented only
# after a file has actually been scanned, so it is evidence of how many
# files this run really read - the denominator of the printed count.
_scan_files() {
    local _pat="$1"
    shift
    local _f _rc _hits=0 _scanned=0
    for _f in "$@"; do
        _rc=0
        grep -q -e "${_pat}" -- "${_f}" || _rc=$?
        case "${_rc}" in
            0) _hits=$((_hits + 1)) ;;
            1) ;;
            *)
                _item_error "grep exited ${_rc} while scanning ${_f} for '${_pat}'"
                return 1
                ;;
        esac
        _scanned=$((_scanned + 1))
    done
    SCAN_HITS="${_hits}"
    SCAN_SCANNED="${_scanned}"
    return 0
}

# Print how many lines of file $2 match pattern $1.
#
# grep -c answers 0 with status 1 when nothing matched, so status 1 is a
# legitimate zero and only status >= 2 is an error. The printed value is
# checked to be a number before anyone uses it as one, so a grep that
# answers with something else cannot be read as a count.
_count_lines() {
    local _pat="$1" _file="$2" _out _rc=0
    _out="$(grep -c -e "${_pat}" -- "${_file}")" || _rc=$?
    if [[ "${_rc}" -gt 1 ]]; then
        _item_error "grep exited ${_rc} while counting '${_pat}' in ${_file}"
        return 1
    fi
    if [[ ! "${_out}" =~ ^[0-9]+$ ]]; then
        _item_error "grep -c answered '${_out}' (not a count) for '${_pat}' in ${_file}"
        return 1
    fi
    printf '%s\n' "${_out}"
    return 0
}

# --- Item 4.1 ----------------------------------------------------------------
#
# Prints, on stdout and in the document's order:
#   svg=<n>  foreignobject=<hits>/<scanned>  mxfile=<hits>/<scanned>
#   readme=<n>  flow-wording=<n>
#
# Every line is printed before it is judged, so a failing run still shows
# the whole familiar block; the mismatches are then named on stderr and the
# item fails. A missing input, an unreadable one or a broken grep aborts
# BEFORE any line is printed - a partial block is not a result.
_item_4_1() {
    local _dir="${VERIFY_ROOT}/doc/diagram"
    local _readme="${VERIFY_ROOT}/README.md"
    local _flow="${_dir}/flow.drawio.svg"
    local _f _readme_refs _flow_wording _bad=0

    _require_tool grep || return $?
    _require_dir "${_dir}" || return 1
    _collect_svgs "${_dir}" || return 1
    # Every file about to be counted - the globbed diagrams, the README and
    # the flow diagram named explicitly (it must be one of the three, and
    # its absence must not hide behind the glob).
    for _f in "${DIAGRAM_SVGS[@]}" "${_readme}" "${_flow}"; do
        _require_file "${_f}" || return 1
    done

    printf 'svg=%s\n' "${#DIAGRAM_SVGS[@]}"
    _expect_eq svg "${#DIAGRAM_SVGS[@]}" "${EXPECT_SVG_COUNT}" || _bad=1

    _scan_files "${PAT_FOREIGNOBJECT}" "${DIAGRAM_SVGS[@]}" || return 1
    printf 'foreignobject=%s/%s\n' "${SCAN_HITS}" "${SCAN_SCANNED}"
    _expect_eq foreignobject-scanned "${SCAN_SCANNED}" "${#DIAGRAM_SVGS[@]}" || _bad=1
    _expect_eq foreignobject-hits "${SCAN_HITS}" "${EXPECT_FOREIGNOBJECT_HITS}" || _bad=1

    _scan_files "${PAT_MXFILE}" "${DIAGRAM_SVGS[@]}" || return 1
    printf 'mxfile=%s/%s\n' "${SCAN_HITS}" "${SCAN_SCANNED}"
    _expect_eq mxfile-scanned "${SCAN_SCANNED}" "${#DIAGRAM_SVGS[@]}" || _bad=1
    _expect_eq mxfile-hits "${SCAN_HITS}" "${SCAN_SCANNED}" || _bad=1

    _readme_refs="$(_count_lines "${PAT_README_REF}" "${_readme}")" || return 1
    printf 'readme=%s\n' "${_readme_refs}"
    _expect_eq readme "${_readme_refs}" "${EXPECT_README_REFS}" || _bad=1

    _flow_wording="$(_count_lines "${PAT_FLOW_WORDING}" "${_flow}")" || return 1
    printf 'flow-wording=%s\n' "${_flow_wording}"
    _expect_eq flow-wording "${_flow_wording}" "${EXPECT_FLOW_WORDING}" || _bad=1

    return "${_bad}"
}

# --- Dispatch ----------------------------------------------------------------

# True iff $1 is one of VERIFY_ITEMS.
_is_known_item() {
    local _i
    for _i in "${VERIFY_ITEMS[@]}"; do
        [[ "${_i}" == "$1" ]] && return 0
    done
    return 1
}

# Run item $1. The default branch is unreachable while VERIFY_ITEMS and the
# branches agree, and it fails loudly rather than returning 0 if they ever
# drift apart.
_run_item() {
    case "$1" in
        4.1) _item_4_1 ;;
        *)
            _item_error "no implementation for this item (VERIFY_ITEMS and _run_item disagree)"
            return 1
            ;;
    esac
}

# The root must be a worktool checkout. Normalises it to an absolute path.
# Anything else is a refused command line (2), not a failed item.
_resolve_root() {
    local _root="$1" _abs
    if [[ ! -d "${_root}" ]]; then
        log_error "--root is not a directory: ${_root}"
        return 2
    fi
    _abs="$(cd -- "${_root}" && pwd -P)"
    if [[ -z "${_abs}" ]]; then
        log_error "--root cannot be resolved: ${_root}"
        return 2
    fi
    if [[ ! -f "${_abs}/${VERIFY_SELF_REL}" ]]; then
        log_error "not a worktool checkout (missing ${VERIFY_SELF_REL}): ${_abs}"
        return 2
    fi
    VERIFY_ROOT="${_abs}"
    return 0
}

# --- Main --------------------------------------------------------------------
diagram_run() {
    local _help=0 _root="${SELF_ROOT}" _items=() _item _rc=0

    # The whole command line is parsed and validated before anything runs.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root)
                shift
                if [[ $# -eq 0 ]]; then
                    _usage_error "--root requires a path argument"
                    return 2
                fi
                _root="$1"
                ;;
            --root=*) _root="${1#*=}" ;;
            --realbox) VERIFY_REALBOX=1 ;;
            # Recorded, not served: `--help --bogus` is a usage error.
            -h|--help) _help=1 ;;
            -*)
                _usage_error "unknown option '$1'"
                return 2
                ;;
            *)
                _items+=("$1")
                ;;
        esac
        shift
    done

    if [[ "${_help}" -eq 1 ]]; then
        _usage
        return 0
    fi

    _diagram_selected_items
}

# Uses diagram_run's local root and item selection after parsing.
_diagram_selected_items() {
    if [[ "${#_items[@]}" -eq 0 ]]; then
        _items=("${VERIFY_ITEMS[@]}")
    fi
    for _item in "${_items[@]}"; do
        if ! _is_known_item "${_item}"; then
            _usage_error "unknown item '${_item}'"
            return 2
        fi
    done

    _resolve_root "${_root}" || return $?

    if [[ "${VERIFY_REALBOX}" -eq 1 ]]; then
        log_info "--realbox: diagram.sh declares no real-machine items; nothing extra will run and no box is touched"
    fi

    for _item in "${_items[@]}"; do
        VERIFY_ITEM="${_item}"
        log_info "${_item}: checking ${VERIFY_ROOT}"
        _rc=0
        _run_item "${_item}" || _rc=$?
        if [[ "${_rc}" -ne 0 ]]; then
            [[ "${_rc}" -eq 3 ]] || log_error "${_item}: FAILED"
            return "${_rc}"
        fi
        log_info "${_item}: PASS"
    done
    return 0
}

# Guard: only run when executed directly, not when sourced (keeps the file
# importable by tests).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    diagram_run "$@"
fi
