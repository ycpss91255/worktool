#!/usr/bin/env bash
# .agents/hook/enforce_codex_round_cap.sh - Claude Code PreToolUse hook
# (matcher: Bash), registered in .claude/settings.json.
#
# pr-loop runs 3 codex fix rounds. A PR that keeps collecting the same
# class of finding past that (PR #219 ran 8 rounds) has a design problem,
# not a wording problem: patching finding by finding only moves the next
# hole. This hook BLOCKS (exit 2, reason on stderr) a `codex exec` whose
# prompt says "第 N 輪" with N >= 4 unless the prompt carries the agent's
# own root-cause analysis: a "## 根因" section (up to the next "# " / "## "
# heading) holding three non-empty items, one line each,
#   類別: <which class / dimension the earlier blocking findings share>
#   根因: <why the class keeps coming back, e.g. a deny-list, one-example
#         tests, an unpinned scope, the same parser written twice>
#   修法: <the fix for the whole class and its equivalence-class tests>
# (optionally list-marked `- ` / `* ` / `1.`; `:` or full-width `：`).
# No maintainer approval is involved: the agent does the analysis itself.
# Rounds 1-3, and prompts without a round, pass.
#
# Only real launches count: lib/subcommand.sh reduces the command to its
# sub-commands (wrappers such as env / sudo / bash -c / eval stripped, a
# leading timeout(1) skipped), so a commit message or an echo that merely
# mentions `codex exec` is data. The prompt is every word after
# `codex exec` (or its alias `codex e`). Every launch is judged on its own:
# a command with rounds 4 and 5 needs the root cause in both prompts.
#
# The hook reads the prompt as literal text only, and fails closed on what
# it cannot read (blocked): each `$(cat <path>)` with
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
#       the N of the FIRST "第 N 輪" in the text, leading zeros dropped;
#       nothing when none. pr-loop declares the round ("這是第 N 輪:")
#       before it quotes the prior verdict, and that verdict (or quoted
#       issue text) may name later rounds, so the first mention is the
#       round and later ones are data
#   codex_root_cause_ok <prompt_text>
#       0 when the text has a "## 根因" section with 類別 / 根因 / 修法
#       each followed by non-blank text
#   codex_prompt_allowed <prompt_text>
#       0 when the prompt has no round, a round below 4, or a complete
#       root-cause section
#   codex_command_refusals <command> <cwd>
#       one line per codex exec launch of the command the hook refuses:
#       its round, or `?` when its prompt cannot be read; an allowed
#       launch prints nothing
#
# Output contract: allow = exit 0, no output; block = exit 2 with the
# "[hook:enforce-codex-round-cap] BLOCKED" reason on stderr.

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
hook_bootstrap "enforce-codex-round-cap"

# The first round whose prompt must carry the root cause.
readonly CODEX_ROOT_CAUSE_ROUND=4

# _num_ge <a> <b> - 0 when the digit string <a> >= <b> (no leading zeros),
# compared by length and then text, never by shell arithmetic.
_num_ge() {
    (( ${#1} != ${#2} )) && { (( ${#1} > ${#2} )); return; }
    [[ ! "$1" < "$2" ]]
}

# codex_round_of <prompt_text> - see the header.
codex_round_of() {
    local _re='第[[:space:]]*([0-9]+)[[:space:]]*輪' _n
    [[ "${1:-}" =~ ${_re} ]] || return 0
    _n="${BASH_REMATCH[1]}"
    while [[ "${_n}" == 0?* ]]; do _n="${_n#0}"; done
    printf '%s\n' "${_n}"
}

# _root_cause_section <prompt_text> - the lines under the first "## 根因"
# heading, up to the next "# " / "## " heading (CR line ends dropped).
_root_cause_section() {
    local _line _in=''
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
        _line="${_line%$'\r'}"
        if [[ -z "${_in}" ]]; then
            [[ "${_line}" =~ ^##[[:space:]]*根因[[:space:]]*$ ]] && _in=1
            continue
        fi
        [[ "${_line}" =~ ^#{1,2}([[:space:]]|$) ]] && break
        printf '%s\n' "${_line}"
    done <<<"${1:-}"
}

# codex_root_cause_ok <prompt_text> - see the header.
codex_root_cause_ok() {
    local _section _label
    _section="$(_root_cause_section "${1:-}")"
    for _label in 類別 根因 修法; do
        grep -qE "^[[:space:]]*([-*]|[0-9]+[.)])?[[:space:]]*${_label}[[:space:]]*(:|：)[[:space:]]*[^[:space:]]" \
            <<<"${_section}" || return 1
    done
}

# codex_prompt_allowed <prompt_text> - see the header.
codex_prompt_allowed() {
    local _round
    _round="$(codex_round_of "${1:-}")"
    [[ -n "${_round}" ]] || return 0
    _num_ge "${_round}" "${CODEX_ROOT_CAUSE_ROUND}" || return 0
    codex_root_cause_ok "${1:-}"
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

# codex_command_refusals <command> <cwd> - see the header.
codex_command_refusals() {
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
        if ! _prompt="$(_launch_prompt "${_sub}" "${_dir}")"; then
            printf '?\n'
        elif ! codex_prompt_allowed "${_prompt}"; then
            codex_round_of "${_prompt}"
        fi
    done
    return 0
}

# _block_round <round> - block a round whose prompt lacks the root cause.
_block_round() {
    hook_block "codex re-verification round $1 without a complete '## 根因' section in its prompt." \
        "A finding class that keeps coming back is a design problem; another patch only moves the hole." \
        "Find the root cause yourself (no maintainer approval needed) and add it to the prompt:" \
        "  ## 根因" \
        "  - 類別: <the class / dimension the earlier blocking findings share>" \
        "  - 根因: <why it keeps coming back: deny-list, one-example tests, unpinned scope, duplicated parser ...>" \
        "  - 修法: <the fix for the whole class and its equivalence-class tests>"
}

main() {
    hook_read_input
    local _cmd _refusal
    _cmd="$(hook_command)"
    [[ "${_cmd}" == *codex* ]] || hook_allow
    while IFS= read -r _refusal; do
        [[ "${_refusal}" == '?' ]] && hook_block "a codex exec prompt that cannot be read as literal text." \
            "The round check fails closed: pass the prompt inline or as \"\$(cat <file>)\" of an existing file, with no other substitution or \$ in it."
        _block_round "${_refusal}"
    done < <(codex_command_refusals "${_cmd}" "$(hook_field '.cwd')")
    hook_allow
}

# Run main only when executed, so the specs can source the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
