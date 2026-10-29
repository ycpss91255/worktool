#!/usr/bin/env bash
# Track direct window shells without ever signaling the Ghostty process.

ghostty_windows_error() {
    hook_block "Ghostty window cleanup failed: $1" \
        'No unreadable process list or snapshot is treated as an empty window list.'
}

ghostty_processes_read() {
    local table
    table="$(LC_ALL=C ps -eo pid=,ppid=,lstart=,comm=)" ||
        ghostty_windows_error 'cannot read process list.'
    [[ -n "${table}" ]] || ghostty_windows_error 'empty process list.'
    jq -Rsen '
        [inputs | split("\n")[] | select(test("\\S")) |
        (capture("^\\s*(?<pid>[0-9]+)\\s+(?<ppid>[0-9]+)\\s+(?<start>\\S+\\s+\\S+\\s+\\S+\\s+\\S+\\s+\\S+)\\s+(?<comm>.+?)\\s*$") // error("invalid process row")) |
        .start |= gsub("\\s+"; " ")] as $all |
        if ($all | length) == 0 or ($all | map(.pid) | unique | length) != ($all | length)
        then error("invalid process table") else . end |
        $all
    ' <<<"${table}" || ghostty_windows_error 'cannot parse process list.'
}

ghostty_windows_read() {
    local processes
    processes="$(ghostty_processes_read)"
    jq -ce '
        . as $all |
        [$all[] | select((.comm | ascii_downcase) == "ghostty")] as $parents |
        [$all[] as $child | $parents[] | select(.pid == $child.ppid) |
        {pid:$child.pid, start:$child.start, parent:.pid, parentStart:.start}]
    ' <<<"${processes}" || ghostty_windows_error 'cannot extract window shells.'
}

ghostty_windows_path() {
    local key
    key="$(jq -ce '[.session_id,.tool_use_id] |
        if all(.[]; type == "string" and length > 0) then .
        else error("missing session/tool ID") end' <<<"${HOOK_INPUT}" | sha256sum)" ||
        ghostty_windows_error 'cannot identify the Bash invocation.'
    printf '%s/.agents/state/ghostty-windows/%s.json' "${HOOK_REPO_ROOT}" "${key%% *}"
}

ghostty_windows_pre() {
    local path="$1" windows temp
    windows="$(ghostty_windows_read)"
    mkdir -p -- "${path%/*}" || ghostty_windows_error 'cannot create snapshot directory.'
    temp="$(mktemp "${path}.XXXXXX")" || ghostty_windows_error 'cannot create snapshot.'
    if ! jq -n --arg command "$(hook_command)" --argjson windows "${windows}" \
        '{command:$command,windows:$windows}' > "${temp}" || ! mv -- "${temp}" "${path}"; then
        ghostty_windows_error 'cannot save snapshot.'
    fi
}

ghostty_windows_close() {
    local candidate="$1" current pid
    pid="$(jq -r '.pid' <<<"${candidate}")"
    current="$(ghostty_windows_read)"
    if ! jq -e --argjson candidate "${candidate}" 'index($candidate) != null' \
        <<<"${current}" >/dev/null; then
        ghostty_windows_error "window shell PID ${pid} identity changed; no signal sent."
    fi
    if ! env kill -HUP -- "${pid}"; then
        ghostty_windows_error "cannot terminate window shell PID ${pid}."
    fi
}

ghostty_windows_post() {
    local path="$1" current added candidate closed=''
    current="$(ghostty_windows_read)"
    added="$(jq -ce --arg command "$(hook_command)" --argjson current "${current}" '
        def valid_window:
            type == "object" and
            all(.pid, .parent; type == "string" and test("^[1-9][0-9]*$")) and
            all(.start, .parentStart; type == "string" and length > 0);
        if type != "object" or .command != $command or
            (.windows | type) != "array" or (all(.windows[]; valid_window) | not) then
            error("invalid snapshot") else $current - .windows end' "${path}")" ||
        ghostty_windows_error 'cannot compare window snapshots.'
    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        ghostty_windows_close "${candidate}"
        closed+=" $(jq -r '.pid' <<<"${candidate}")"
    done < <(jq -c '.[]' <<<"${added}")
    rm -- "${path}" || ghostty_windows_error 'cannot remove consumed snapshot.'
    [[ -n "${closed}" ]] || return 0
    hook_context "Closed new Ghostty window shell PIDs:${closed}" PostToolUse
}

ghostty_windows_track() {
    local event path
    event="$(hook_field '.hook_event_name')"
    # Empty compatibility probes do not represent Bash executions.
    [[ -n "$(hook_command)" ]] || return 0
    event="${event:-PreToolUse}"
    path="$(ghostty_windows_path)"
    case "${event}" in
        PreToolUse) ghostty_windows_pre "${path}" ;;
        PostToolUse) ghostty_windows_post "${path}" ;;
        *) ghostty_windows_error 'unknown hook event.' ;;
    esac
}
