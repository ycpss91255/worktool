#!/usr/bin/env bash
# .agents/hook/enforce_issue_milestone.sh - Claude Code PreToolUse hook
# (matcher: Bash), registered in .claude/settings.json.
#
# Issue #266: an issue that belongs to a milestone gets that milestone (M1,
# M2, ...), one that does not gets none. #249 and #173 were filed without
# one they belonged to, and nothing said so. The filer therefore declares
# it when filing, and this hook BLOCKS (exit 2) a real `gh issue create`
# launch that does not carry exactly one of:
#   --milestone <name> / --milestone=<name> / -m <name> / -m<name>
#   (a blank value, or one that is really the next option, counts as none)
#   a body line `milestone: 無` (a line of its own; a full-width colon and
#   surrounding blanks are fine), read from --body / -b, --body-file / -F
#   (a relative path is resolved against the tool call's cwd), or a stdin
#   body (-F -) that lib/issue_body.sh can see
# Both at once contradict each other and are blocked too.
#
# 擋: every gh issue create launch, also one run through bash -c / eval
#   (lib/subcommand.sh), its stdin body read inside that nested script.
# 不擋: gh issue edit, gh pr create, quoted text or heredoc bodies that merely
#   mention gh issue create. The milestone name is not checked (gh rejects
#   an unknown one), nor is which milestone the issue should get.
# 已知限制 (fail closed): a body the hook cannot read (a missing file, a
#   stdin body from a printf pipe, a < file, ...) never counts as
#   `milestone: 無`, so such a launch needs --milestone or a readable body.
#
# Output contract: allow = exit 0, no output; block = exit 2 with the
# reason on stderr (lib/hook_bootstrap.sh hook_block).

# shellcheck source-path=SCRIPTDIR/lib
_HOOK_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook_bootstrap.sh
source "${_HOOK_HERE}/lib/hook_bootstrap.sh"
# shellcheck source=subcommand.sh
source "${_HOOK_HERE}/lib/subcommand.sh"
# shellcheck source=issue_body.sh
source "${_HOOK_HERE}/lib/issue_body.sh"
hook_bootstrap "enforce-issue-milestone"

# _says_no_milestone <body> - 0 when a line of the body is `milestone: 無`.
_says_no_milestone() {
    grep -qiE '^[[:space:]]*milestone[[:space:]]*(:|：)[[:space:]]*無[[:space:]]*$' <<<"${1//$'\r'/}"
}

# _stdin_body <command> - the stdin body of the one gh issue create launch,
# looked for in the command and in every bash -c / eval script it runs.
_stdin_body() {
    local _script _body
    while IFS= read -r -d '' _script; do
        _body="$(hook_issue_stdin_body "${_script}")"
        if [[ -n "${_body}" ]]; then
            printf '%s' "${_body}"
            return 0
        fi
    done < <(hook_scripts "$1")
}

# _judge_launch <encoded gh issue create launch> <whole command> - print the
# block reason, or nothing.
_judge_launch() {
    local -a _w
    local _i _ms='' _body='' _file=''
    read -r -a _w <<<"$1"
    for ((_i = 0; _i < ${#_w[@]}; _i++)); do
        case "${_w[_i]}" in
            --milestone|-m) _ms="$(hook_word "${_w[_i + 1]:-}")" ;;
            --milestone=*) _ms="$(hook_word "${_w[_i]#*=}")" ;;
            -m?*) _ms="$(hook_word "${_w[_i]#-m}")" ;;
            --body|-b) _body="$(hook_word "${_w[_i + 1]:-}")" ;;
            --body=*) _body="$(hook_word "${_w[_i]#*=}")" ;;
            --body-file|-F) _file="$(hook_word "${_w[_i + 1]:-}")" ;;
            --body-file=*) _file="$(hook_word "${_w[_i]#*=}")" ;;
        esac
    done
    if [[ "${_file}" == "-" ]]; then
        _body="$(_stdin_body "$2")"
    elif [[ -n "${_file}" ]]; then
        _body="$(hook_read_body_file "${_file}")" || _body=''
    fi
    # An empty quoted value leaves no word behind (lib/subcommand.sh), so a
    # value that looks like the next option means there was none.
    [[ "${_ms}" == -* ]] && _ms=''
    if [[ -n "${_ms//[[:space:]]/}" ]]; then
        _says_no_milestone "${_body}" \
            && printf '%s' "gh issue create has --milestone '${_ms}' and a body line 'milestone: 無'; they contradict each other. Keep exactly one."
        return 0
    fi
    _says_no_milestone "${_body}" && return 0
    printf '%s' "gh issue create must say whether the issue belongs to a milestone (issue #266): pass --milestone <name> (or -m <name>) when it belongs to one, or put a line 'milestone: 無' in the body when it does not. A body the hook cannot read (a missing file, a stdin body other than a heredoc on the gh line or 'cat <one file> |') does not count."
}

main() {
    hook_read_input
    local _cmd _sub _reason=''
    _cmd="$(hook_command)"
    while IFS= read -r _sub; do
        [[ "${_sub}" =~ ^gh[[:space:]]+issue[[:space:]]+create([[:space:]]|$) ]] || continue
        _reason="$(_judge_launch "${_sub}" "${_cmd}")"
        [[ -n "${_reason}" ]] && break
    done < <(hook_subcommands_raw "${_cmd}")
    [[ -n "${_reason}" ]] && hook_block "${_reason}"
    return 0
}

main "$@"
