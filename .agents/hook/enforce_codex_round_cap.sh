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
# `codex exec` (or its alias `codex e`); a word that is a command
# substitution whose body is `cat <path>` - the `"$(cat prompt.txt)"` form
# pr-loop uses - is replaced by the file's text. A relative path resolves
# against the last `cd <dir>` before the launch, else the payload's cwd.
#
# Functions (the file can be sourced; main runs only when executed):
#   codex_round_of <prompt_text>
#       the largest N of every "第 N 輪" in the text; nothing when none
#   codex_round_allowed <round> <user_msg>
#       0 when the round is empty or below 4, or the message says
#       `approve codex round <round>` (words case-insensitive, exact N)
#   codex_command_round <command> <cwd>
#       the largest round among the command's codex exec launches
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

# codex_round_of <prompt_text> - see the header.
codex_round_of() {
    local _n _max=''
    while IFS= read -r _n; do
        [[ -n "${_n}" ]] || continue
        _n=$((10#${_n}))
        [[ -z "${_max}" || "${_n}" -gt "${_max}" ]] && _max="${_n}"
    done < <(printf '%s' "${1:-}" | grep -oE '第[[:space:]]*[0-9]+[[:space:]]*輪' | grep -oE '[0-9]+')
    [[ -n "${_max}" ]] && printf '%s\n' "${_max}"
    return 0
}

# codex_round_allowed <round> <user_msg> - see the header.
codex_round_allowed() {
    local _round="${1:-}" _msg
    [[ -n "${_round}" ]] || return 0
    (( _round < CODEX_ROUND_CAP )) && return 0
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

# _launch_prompt <index> <dir> <launch...> - the prompt text of the codex
# exec launch at <index> of the sub-command list: its inline words, plus
# the file of each `cat <path>` substitution body that follows it.
_launch_prompt() {
    local _i="$1" _dir="$2" _word _k=0
    shift 2
    local -a _subs=("$@")
    while IFS= read -r _word; do
        if hook_word_has_subst "${_word}"; then
            _k=$((_k + 1))
            [[ "${_subs[_i + _k]:-}" =~ ^cat[[:space:]]+([^[:space:]]+)$ ]] || continue
            cat -- "$(_resolve_path "$(hook_word "${BASH_REMATCH[1]}")" "${_dir}")" 2>/dev/null
        else
            hook_word "${_word}"
        fi
        printf '\n'
    done < <(_codex_words "${_subs[_i]}")
}

# codex_command_round <command> <cwd> - see the header.
codex_command_round() {
    local _dir="${2:-${PWD}}" _i _round _max=''
    local -a _subs
    mapfile -t _subs < <(hook_subcommands_raw "${1:-}")
    for ((_i = 0; _i < ${#_subs[@]}; _i++)); do
        if [[ "${_subs[_i]}" =~ ^cd[[:space:]]+([^[:space:]]+)$ ]]; then
            _dir="$(_resolve_path "$(hook_word "${BASH_REMATCH[1]}")" "${_dir}")"
            continue
        fi
        _codex_words "${_subs[_i]}" >/dev/null || continue
        _round="$(codex_round_of "$(_launch_prompt "${_i}" "${_dir}" "${_subs[@]}")")"
        [[ -n "${_round}" && ( -z "${_max}" || "${_round}" -gt "${_max}" ) ]] && _max="${_round}"
    done
    [[ -n "${_max}" ]] && printf '%s\n' "${_max}"
    return 0
}

main() {
    hook_read_input
    local _cmd _round _msg=''
    _cmd="$(hook_command)"
    [[ "${_cmd}" == *codex* ]] || hook_allow
    _round="$(codex_command_round "${_cmd}" "$(hook_field '.cwd')")"
    if [[ -n "${_round}" ]] && (( _round >= CODEX_ROUND_CAP )); then
        _msg="$(read_latest_user_message "$(hook_field '.transcript_path')")"
    fi
    codex_round_allowed "${_round}" "${_msg}" && hook_allow
    hook_block "codex re-verification round ${_round} (pr-loop allows 3 fix rounds)." \
        "A finding class that keeps coming back is a design problem; another patch only moves the hole. Stop and find the root cause first:" \
        "  1. deny-list patched item by item? Switch to normalisation or an allow-list." \
        "  2. tests that add one example per finding? Switch to an equivalence-class test matrix." \
        "  3. does the issue have a '## 範圍' section that pins the scope? If not, agree on it before more rounds." \
        "Then report the root cause to the maintainer and ask for a reply of: approve codex round ${_round}"
}

# Run main only when executed, so the specs can source the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
