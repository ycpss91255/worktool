#!/usr/bin/env bats

@test "PTY process session probe" {
    local _child_file="${BATS_TEST_TMPDIR}/child" _launcher _child _stat
    cat >"${BATS_TEST_TMPDIR}/child.sh" <<'SCRIPT'
printf '%s\n' "$$" >"${CHILD_FILE}"
exec sleep 60
SCRIPT
    CHILD_FILE="${_child_file}" setsid timeout 30 script -qec "bash ${BATS_TEST_TMPDIR}/child.sh" /dev/null </dev/null >/dev/null 2>&1 &
    _launcher=$!
    trap 'if [[ -n "${_child:-}" ]]; then kill -KILL "${_child}" 2>/dev/null || :; fi; kill -KILL -- "-${_launcher}" 2>/dev/null || :; wait "${_launcher}" 2>/dev/null || :' RETURN
    timeout 5 bash -c 'until [[ -s "$1" ]]; do sleep 0.05; done' _ "${_child_file}"
    _child="$(cat "${_child_file}")"
    _stat="$(cat "/proc/${_child}/stat")"
    printf '# launcher=%s child stat=%s\n' "${_launcher}" "${_stat}" >&3
    kill -KILL "${_child}" 2>/dev/null || :
    kill -KILL -- "-${_launcher}" 2>/dev/null || :
    wait "${_launcher}" 2>/dev/null || :
    trap - RETURN
}
