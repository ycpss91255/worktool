#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"
load "${BATS_TEST_DIRNAME}/../helper/realbox_window"

bats_require_minimum_version 1.5.0

setup() {
    _prepare_realbox_tools
}

_prepare_52_doc_tools() {
    _auto_window_tools
    cp "${STUBS}/just" "${STATE}/just"
    export DOC_ENTER="${REPO_ROOT}/script/box/enter.sh"
    export FAKE_JUST_BOX_SCRIPT_DIR="${REPO_ROOT}/script/box"
    cat >"${STUBS}/just" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${2:-}" == enter ]]; then exec "${DOC_ENTER}" "${@:3}"; fi
exec "${FAKE_STATE_DIR}/just" "$@"
STUB
    cp "${STUBS}/docker" "${STATE}/docker"
    cat >"${STUBS}/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    inspect)
        # enter.sh asks State.Running while the log follower may still be
        # catching up; answer it as a running box, not the StartedAt value.
        if [[ "$*" == *'.State.Running'* ]]; then printf 'true\n'
        else printf '0001-01-01T00:00:00Z\n'; fi ;;
    start) mkdir -p "${XDG_CACHE_HOME%/cache}/box-home/.cache/tmux" ;;
    logs) printf 'container_setup_done\n' ;;
    *) exec "${FAKE_STATE_DIR}/docker" "$@" ;;
esac
STUB
}

_52_doc_stream() {
    awk -v stream="$2" '
        /^  - \[ \] 5\.2 開終端/ {section=1}
        /^  - \[ \] 5\.3 / {section=0}
        section && $0 == "      ````text " stream {block=1; next}
        block && /^      ````$/ {exit}
        block {sub(/^      /, ""); print}' "$1"
}

_normalize_52_doc() {
    sed -E 's@[a-f0-9]{64}@<sha>@g;
        s@/(tmp|source)/[^ '"'"']+@<path>@g;
        s/after [0-9]+s/after <elapsed>/g;
        s/pid=[0-9]+/pid=<pid>/g;
        s/mnt:\[[0-9]+\]/mnt:[<ns>]/g'
}

_normalize_52_doc_stderr() {
    _normalize_52_doc
}

_assert_52_doc() {
    local output="" stderr=""
    run --separate-stderr "${REALBOX}" --allow-real-box 5.2 </dev/null
    if ! assert_success; then printf '%s\n' "${stderr}"; return 1; fi
    DOC_52_OUTPUT="${output}" DOC_52_STDERR="${stderr}"
    _compare_52_doc "$1" "${output}" "${stderr}"
}

_compare_52_doc() {
    local expected section output="$2" stderr="$3"
    section="$(sed -n '/^  - \[ \] 5\.2 開終端/,/^  - \[ \] 5\.3 /p' "$1")"
    [[ "${section}" == *'box-state before-cleanup: home=1 tmux=1'* ]] || return 1
    expected="$(_52_doc_stream "$1" stdout)"
    assert_equal "$(printf '%s\n' "${output}" | _normalize_52_doc)" \
        "$(printf '%s\n' "${expected}" | _normalize_52_doc)" || return 1
    expected="$(_52_doc_stream "$1" stderr)"
    assert_equal "$(printf '%s\n' "${stderr}" | _normalize_52_doc_stderr)" \
        "$(printf '%s\n' "${expected}" | _normalize_52_doc_stderr)"
}

@test "#691: acceptance 5.2 compares first-start stdout and stderr bidirectionally" {
    _prepare_52_doc_tools
    local doc="${REPO_ROOT}/doc/acceptance.md" mutant="${BATS_TEST_TMPDIR}/mutant.md"
    _assert_52_doc "${doc}"
    sed '/^      phase=first-start$/d' "${doc}" >"${mutant}"
    run _compare_52_doc "${mutant}" "${DOC_52_OUTPUT}" "${DOC_52_STDERR}"
    assert_failure
    sed '/^      backup-covers=5\/5$/d' "${doc}" >"${mutant}"
    run _compare_52_doc "${mutant}" "${DOC_52_OUTPUT}" "${DOC_52_STDERR}"
    assert_failure
    sed '/^      ````text stderr$/a\      unexpected=1' "${doc}" >"${mutant}"
    run _compare_52_doc "${mutant}" "${DOC_52_OUTPUT}" "${DOC_52_STDERR}"
    assert_failure
    sed '/^      ````text stdout$/a\      unexpected=1' "${doc}" >"${mutant}"
    run _compare_52_doc "${mutant}" "${DOC_52_OUTPUT}" "${DOC_52_STDERR}"
    assert_failure
    sed 's/box-state before-cleanup: home=1 tmux=1/box-state before-cleanup: home=1 tmux=0/g' "${doc}" >"${mutant}"
    run _compare_52_doc "${mutant}" "${DOC_52_OUTPUT}" "${DOC_52_STDERR}"
    assert_failure
    run _compare_52_doc "${doc}" "${DOC_52_OUTPUT}"$'\nunexpected=1' "${DOC_52_STDERR}"
    assert_failure
    run _compare_52_doc "${doc}" "${DOC_52_OUTPUT}" "${DOC_52_STDERR}"$'\n[INFO] wrote: unexpected'
    assert_failure
    run _compare_52_doc "${doc}" "${DOC_52_OUTPUT}" "${DOC_52_STDERR/phase=first-start/}"
    assert_failure
}
