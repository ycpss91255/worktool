#!/usr/bin/env bash
# .agents/hook/enforce_codex_round_cap.sh - Claude Code PreToolUse hook
# (matcher: Bash), registered in .claude/settings.json.
#
# pr-loop runs at most 3 codex fix rounds. A PR that keeps collecting the
# same class of finding past that (PR #219 ran 8 rounds) has a design
# problem, not a wording problem: continuing to patch finding by finding
# only moves the next hole. This hook BLOCKS (exit 2, reason on stderr) a
# `codex exec` whose prompt says "第 N 輪" with N >= 4 unless the latest
# user-typed message of the session transcript says `approve codex round N`
# (the exact N). Rounds 1-3, and prompts without a round, pass.
#
# Only real launches count: lib/subcommand.sh reduces the command to its
# sub-commands (wrappers such as env / sudo / bash -c / eval stripped, a
# leading timeout(1) skipped), so a commit message or an echo that merely
# mentions `codex exec` is data. The prompt is every word after
# `codex exec` (or its alias `codex e`). Every launch is judged on its own:
# a command with rounds 4 and 5 needs both approvals.
#
# The hook reads the prompt as literal text only, and fails closed on what
# it cannot read (blocked, and no approval helps): each `$(cat <path>)` with
# a plain path - the `"$(cat prompt.txt)"` form pr-loop uses - is replaced
# by the file's text, in place inside its word; a missing file, any other
# $(...) / `...` substitution, and any `$` left in a word (a variable,
# $'...') block the launch. A relative path resolves against the last
# `cd <dir>` before the launch, else the payload's cwd. Round numbers stay
# digit strings (compared by length, then text), so no N overflows.
# Out of scope: a prompt fed on stdin, brace or glob expansion; the hook
# guards a cooperating agent's pr-loop, it is not a sandbox.
#
# Functions (the file can be sourced; main runs only when executed):
#   codex_round_of <prompt_text>
#       the largest N of every "第 N 輪" in the text, leading zeros
#       dropped; nothing when none
#   codex_round_allowed <round> <user_msg>
#       0 when the round is empty or below 4, or the message says
#       `approve codex round <round>` (words case-insensitive, exact N)
#   codex_command_rounds <command> <cwd>
#       one line per codex exec launch of the command: its round, or `?`
#       when its prompt cannot be read; a launch without a round prints
#       nothing
#
# Output contract: allow = exit 0, no output; block = exit 2 with the
# "[hook:enforce-codex-round-cap] BLOCKED" reason on stderr.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
# shellcheck source=transcript.sh
source "${_HOOK_HERE}/lib/transcript.sh"
hook_bootstrap "enforce-codex-round-cap"

# The first round that needs the maintainer's approval.
readonly CODEX_ROUND_CAP=4

# _num_ge <a> <b> - 0 when the digit string <a> >= <b> (no leading zeros),
# compared by length and then text, never by shell arithmetic.
_num_ge() {
    (( ${#1} != ${#2} )) && { (( ${#1} > ${#2} )); return; }
    [[ ! "$1" < "$2" ]]
}

# codex_round_of <prompt_text> - see the header.
codex_round_of() {
    local _n _max=''
    while IFS= read -r _n; do
        while [[ "${_n}" == 0?* ]]; do _n="${_n#0}"; done
        [[ -n "${_n}" ]] || continue
        if [[ -z "${_max}" ]] || ! _num_ge "${_max}" "${_n}"; then
            _max="${_n}"
        fi
    done < <(printf '%s' "${1:-}" | grep -oE '第[[:space:]]*[0-9]+[[:space:]]*輪' | grep -oE '[0-9]+')
    [[ -n "${_max}" ]] && printf '%s\n' "${_max}"
    return 0
}

# codex_round_allowed <round> <user_msg> - see the header.
codex_round_allowed() {
    local _round="${1:-}" _msg
    [[ -n "${_round}" ]] || return 0
    [[ "${_round}" =~ ^[0-9]+$ ]] || return 1
    _num_ge "${_round}" "${CODEX_ROUND_CAP}" || return 0
    _msg="$(printf '%s' "${2:-}" | tr '[:upper:]\n' '[:lower:] ')"
    printf '%s' "${_msg}" | grep -qE \
        "(^|[^[:alnum:]_])approve[[:space:]]+codex[[:space:]]+round[[:space:]]+${_round}([^[:alnum:]_]|\$)"
}

# _resolve_path <path> <dir> - the path, relative ones joined to <dir>.
_resolve_path() {
    local _p="$1"
    [[ "${_p}" == /* ]] || _p="${2%/}/${_p}"
    printf '%s' "${_p}"
}

# _codex_words <encoded launch> - the launch's words after `codex exec`,
# still encoded, one per line; fail when it is not a codex exec launch.
_codex_words() {
    local _re='^g?timeout([[:space:]]+[^[:space:]0-9][^[:space:]]*)*[[:space:]]+[0-9][^[:space:]]*[[:space:]]+'
    local _l="$1"
    local -a _w
    [[ "${_l}" =~ ${_re} ]] && _l="$(_hook_strip_wrappers "${_l#"${BASH_REMATCH[0]}"}")"
    read -r -a _w <<<"${_l}"
    [[ "${_w[0]:-}" == codex || "${_w[0]:-}" == */codex ]] || return 1
    [[ "${_w[1]:-}" == exec || "${_w[1]:-}" == e ]] || return 1
    (( ${#_w[@]} > 2 )) && printf '%s\n' "${_w[@]:2}"
    return 0
}

# _cat_placeholders <command> - set _CODEX_CMD to the command with each
# `$(cat <plain path>)` replaced by the placeholder \002<k>\002, and
# _CODEX_CAT_PATHS[k] to its path, so the substitution the hook can read
# never reaches the sub-command parser.
_cat_placeholders() {
    local _re='\$\(cat[[:space:]]+([A-Za-z0-9_./+-]+)[[:space:]]*\)' _k=0
    _CODEX_CMD="$1"
    _CODEX_CAT_PATHS=()
    while [[ "${_CODEX_CMD}" =~ ${_re} ]]; do
        _CODEX_CAT_PATHS+=("${BASH_REMATCH[1]}")
        _CODEX_CMD="${_CODEX_CMD/"${BASH_REMATCH[0]}"/$'\002'"${_k}"$'\002'}"
        _k=$((_k + 1))
    done
}

# _word_text <encoded word> <dir> - the word's literal text with each
# placeholder replaced by its file's text; fail when the word holds a
# substitution, a `$`, or a placeholder whose file cannot be read.
_word_text() {
    local _w _out='' _path _text _re=$'\002''([0-9]+)'$'\002'
    hook_word_has_subst "$1" && return 1
    _w="$(hook_word "$1")"
    [[ "${_w}" == *'$'* ]] && return 1
    while [[ "${_w}" =~ ${_re} ]]; do
        _path="$(_resolve_path "${_CODEX_CAT_PATHS[BASH_REMATCH[1]]:-}" "$2")"
        [[ -f "${_path}" && -r "${_path}" ]] || return 1
        _text="$(cat -- "${_path}")" || return 1
        _out+="${_w%%"${BASH_REMATCH[0]}"*}${_text}"
        _w="${_w#*"${BASH_REMATCH[0]}"}"
    done
    printf '%s\n' "${_out}${_w}"
}

# _launch_prompt <launch> <dir> - the prompt text of one codex exec launch;
# fail when a word of it cannot be read (see _word_text).
_launch_prompt() {
    local _word
    local -a _words
    mapfile -t _words < <(_codex_words "$1")
    for _word in "${_words[@]}"; do
        _word_text "${_word}" "$2" || return 1
    done
}

# codex_command_rounds <command> <cwd> - see the header.
codex_command_rounds() {
    local _dir="${2:-${PWD}}" _sub _prompt
    local -a _subs
    # A \002 of its own would pose as a placeholder: unreadable.
    [[ "${1:-}" == *$'\002'* ]] && { printf '?\n'; return 0; }
    _cat_placeholders "${1:-}"
    mapfile -t _subs < <(hook_subcommands_raw "${_CODEX_CMD}")
    for _sub in "${_subs[@]}"; do
        if [[ "${_sub}" =~ ^cd[[:space:]]+([^[:space:]]+)$ ]]; then
            _dir="$(_resolve_path "$(hook_word "${BASH_REMATCH[1]}")" "${_dir}")"
            continue
        fi
        _codex_words "${_sub}" >/dev/null || continue
        if _prompt="$(_launch_prompt "${_sub}" "${_dir}")"; then
            codex_round_of "${_prompt}"
        else
            printf '?\n'
        fi
    done
    return 0
}

# _block_round <round> - block an unapproved round, with the root-cause steps.
_block_round() {
    hook_block "codex re-verification round $1 (pr-loop allows 3 fix rounds)." \
        "A finding class that keeps coming back is a design problem; another patch only moves the hole. Stop and find the root cause first:" \
        "  1. deny-list patched item by item? Switch to normalisation or an allow-list." \
        "  2. tests that add one example per finding? Switch to an equivalence-class test matrix." \
        "  3. does the issue have a '## 範圍' section that pins the scope? If not, agree on it before more rounds." \
        "Then report the root cause to the maintainer and ask for a reply of: approve codex round $1"
}

main() {
    hook_read_input
    local _cmd _round _msg='' _read=''
    _cmd="$(hook_command)"
    [[ "${_cmd}" == *codex* ]] || hook_allow
    while IFS= read -r _round; do
        [[ "${_round}" == '?' ]] && hook_block "a codex exec prompt that cannot be read as literal text." \
            "The round check fails closed: pass the prompt inline or as \"\$(cat <file>)\" of an existing file, with no other substitution or \$ in it."
        codex_round_allowed "${_round}" "" && continue
        if [[ -z "${_read}" ]]; then
            _msg="$(read_latest_user_message "$(hook_field '.transcript_path')")"
            _read=1
        fi
        codex_round_allowed "${_round}" "${_msg}" || _block_round "${_round}"
    done < <(codex_command_rounds "${_cmd}" "$(hook_field '.cwd')")
    hook_allow
}

# Run main only when executed, so the specs can source the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
