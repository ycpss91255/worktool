#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helper/common"

bats_require_minimum_version 1.5.0

_prepare_realbox_doc_stubs() {
    export FAKE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
    export HOME="${BATS_TEST_TMPDIR}/home" TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    export FAKE_WORKTOOL_LIB_DIR="${REPO_ROOT}/lib"
    unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME
    local bin="${BATS_TEST_TMPDIR}/bin" tool
    mkdir -p "${FAKE_STATE_DIR}" "${HOME}" "${TMPDIR}" "${bin}"
    touch "${FAKE_STATE_DIR}/boxes" "${FAKE_STATE_DIR}/calls.log" "${FAKE_STATE_DIR}/list-calls"
    for tool in distrobox gh jq; do
        install -m 0755 "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${bin}/${tool}"
    done
    export DOC_REAL_JUST
    DOC_REAL_JUST="$(command -v just)"
    export DOC_TOOL="${FAKE_STATE_DIR}/just"
    install -m 0755 "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${DOC_TOOL}"
    cat >"${bin}/just" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == verify ]]; then
    if [[ -n "${DOC_EXTRA_STDOUT:-}" ]]; then printf '%s\n' "${DOC_EXTRA_STDOUT}"; fi
    if [[ -n "${DOC_EXTRA_STDERR:-}" ]]; then printf '%s\n' "${DOC_EXTRA_STDERR}" >&2; fi
    if [[ "${DOC_MOVE_RECIPE:-0}" == 1 ]]; then
        printf '%s\n' './script/verify/realbox.sh "$@"'
        exec "${DOC_REAL_JUST}" --quiet "$@"
    fi
    exec "${DOC_REAL_JUST}" "$@"
fi
if [[ "${2:-}" == bench ]]; then
    exec bash "${DOC_BENCH}" "${@:3}"
fi
exec bash "${DOC_TOOL}" "$@"
STUB
    chmod +x "${bin}/just"
    export PATH="${bin}:${PATH}"
    _prepare_doc_bench_commands "${bin}"
}

# Bench and its libraries run for real; the first-start and setup commands are stubbed.
_prepare_doc_bench_commands() {
    local bin="$1"
    export DOC_BENCH="${REPO_ROOT}/script/box/bench.sh"
    mkdir -p "${FAKE_STATE_DIR}/external"
    export DOC_DISTROBOX="${FAKE_STATE_DIR}/external/distrobox"
    install -m 0755 "${BATS_TEST_DIRNAME}/fixture/realbox_tool.sh" "${DOC_DISTROBOX}"
    export BENCH_PSI_FILE="${FAKE_STATE_DIR}/psi"
    export BENCH_BOX_PSI_FILE="${BENCH_PSI_FILE}"
    export BENCH_CLOCK="${bin}/bench-clock"
    printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' >"${BENCH_PSI_FILE}"
    printf '1000000\n' >"${FAKE_STATE_DIR}/clock"
    cat >"${bin}/bench-clock" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cat "${FAKE_STATE_DIR}/clock"
STUB
    cat >"${bin}/sleep" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
exit 0
STUB
    cat >"${bin}/distrobox" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == enter ]]; then
    read -r now <"${FAKE_STATE_DIR}/clock"
    printf '%s\n' "$((now + 10000))" >"${FAKE_STATE_DIR}/clock"
    if [[ "$*" == *bench-inbox* ]]; then printf '1000\n'; fi
    exit 0
fi
exec bash "${DOC_DISTROBOX}" "$@"
STUB
    chmod +x "${bin}/bench-clock" "${bin}/sleep" "${bin}/distrobox"
}

_normalize_realbox_doc_output() {
    sed -E 's/m3-51-[0-9]{8}T[0-9]{6}Z-[0-9]+/<run>/g;
        s/comment=[0-9]+/comment=<id>/g;
        s/^(host-state baseline: present=)[0-9]+/\1<n>/;
        s/^(box-state before-cleanup: home=)[01]( tmux=)[01]$/\1<n>\2<n>/;
        s/(min=|median=|max=)[0-9]+([.][0-9]+)?/\1<n>/g;
        s/median [0-9]+([.][0-9]+)? ms/median <n> ms/g'
}

_normalize_realbox_doc_stderr() {
    # Only omit the optional setup/PSI/progress diagnostics named in section 5.1.
    # Apply this to stderr alone so a diagnostic moved to stdout still fails.
    sed -E '/^\.\/script\/verify\/realbox\.sh "\$@"$/d;
        /^\[INFO\] auto-enter: (yes|no) \((default|user)\)$/d;
        /^\[INFO\] terminal: (ghostty|none) \((default|user)\)$/d;
        /^\[INFO\] box: [^ ]+ \((default|user)\)$/d;
        /^\[INFO\] ghostty config: .+ \(config\.ghostty (exists|absent; legacy fallback)\)$/d;
        /^\[INFO\] distrobox: .+ \((--distrobox; )?absolute path written into the managed command\)$/d;
        /^\[INFO\] wrote: .+\/worktool\/config$/d;
        /^\[INFO\] wrote: .+ \(managed block: .+\)$/d;
        /^\[INFO\] Ghostty config changed: a running Ghostty must reload its config \(Linux default: Ctrl\+Shift\+,\)\. Reload is asynchronous; wait until the config takes effect before opening a new window, or start a new Ghostty process first\. Keep your existing windows open\.$/d;
        /^\[INFO\] box psi wait [0-9]+s: .+ some avg10=[0-9.]+$/d;
        /^\[INFO\] psi (before|after) (enter|shell|inbox) (warmup|run) [0-9]+: .+ some avg10=[0-9.?]+$/d;
        /^\[INFO\] host quiet: .+ some avg10=[0-9.]+ <= 2\.00 for [0-9]+s; loadavg=.+$/d;
        /^\[INFO\] host stayed quiet: .+ some avg10 peak=[0-9.]+ over every run; loadavg=.+$/d;
        /^\[INFO\] (enter|shell|inbox): [0-9]+ warmup \+ [0-9]+ run\(s\) of .+ done$/d' |
        _normalize_realbox_doc_output
}

_assert_realbox_doc_streams() {
    local section expected actual output="" stderr=""
    section="$(sed -n '/^  - \[ \] 5\.1 進盒/,/^  - \[ \] 5\.2 /p' "$1")"
    # Compare complete streams after normalizing environment-dependent fields.
    expected="$(awk '/^      ````text$/ { block=1; next }
        /^      ````$/ && block { exit }
        block { sub(/^      /, ""); print }' <<<"${section}")"
    [[ -n "${expected}" ]] || return 1
    [[ "${expected}" == *"box-state before-cleanup: home=1 tmux=1"* ]] || return 1
    run --separate-stderr just verify realbox --allow-real-box 5.1
    if ! assert_success; then printf '%s\n' "${stderr}"; return 1; fi
    actual="${output}"$'\nrc=0'
    assert_equal "$(printf '%s\n' "${actual}" | _normalize_realbox_doc_output)" \
        "$(printf '%s\n' "${expected}" | _normalize_realbox_doc_output)" || return 1
    expected="$(awk '
        /^      ````text stderr$/ { block=1; next }
        /^      ````$/ && block { exit }
        block { sub(/^      /, ""); print }' <<<"${section}")"
    assert_equal "$(printf '%s\n' "${stderr}" | _normalize_realbox_doc_stderr)" \
        "$(printf '%s\n' "${expected}" | _normalize_realbox_doc_stderr)"
}

@test "acceptance 5.1 normal block matches both output streams bidirectionally (#666)" {
    _prepare_realbox_doc_stubs
    _assert_realbox_doc_streams "${REPO_ROOT}/doc/acceptance.md"
}

@test "acceptance 5.1 comparison rejects stub cleanup state in the real host block (#666)" {
    _prepare_realbox_doc_stubs
    local doc="${BATS_TEST_TMPDIR}/acceptance.md"
    sed 's/box-state before-cleanup: home=1 tmux=1/box-state before-cleanup: home=0 tmux=0/' \
        "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_realbox_doc_streams "${doc}"
    assert_failure
}

@test "acceptance 5.1 successful comparison emits no fd 3 dump (#666)" {
    _prepare_realbox_doc_stubs
    local dump="${BATS_TEST_TMPDIR}/diagnostics"
    run _assert_realbox_doc_streams "${REPO_ROOT}/doc/acceptance.md" 3>"${dump}"
    assert_success
    [[ ! -s "${dump}" ]]
}

@test "acceptance 5.1 comparison rejects a real bench summary moved to stdout (#666)" {
    _prepare_realbox_doc_stubs
    local mutant="${BATS_TEST_TMPDIR}/mutant"
    mkdir -p "${mutant}"
    cp -a "${REPO_ROOT}/script" "${REPO_ROOT}/lib" "${mutant}/"
    export DOC_BENCH="${mutant}/script/box/bench.sh"
    sed -i 's/log_info "shell median \(.*within --max-ms.*\)"/echo "[INFO] shell median \1"/' "${DOC_BENCH}"
    run _assert_realbox_doc_streams "${REPO_ROOT}/doc/acceptance.md"
    assert_failure
    assert_output --partial '-- values do not equal --'
    assert_output --partial '[INFO] shell median'
}

@test "acceptance 5.1 comparison rejects missing and extra documented lines (#999)" {
    _prepare_realbox_doc_stubs
    local doc="${BATS_TEST_TMPDIR}/acceptance.md"
    sed '/^      host-state kept-unknown=0$/d' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_realbox_doc_streams "${doc}"
    assert_failure
    sed '/^      host-state kept-unknown=0$/a\      unexpected=1' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_realbox_doc_streams "${doc}"
    assert_failure
}

@test "acceptance 5.1 rejects script output added or moved to stdout (#999)" {
    _prepare_realbox_doc_stubs
    DOC_EXTRA_STDOUT='./script/unexpected output' run _assert_realbox_doc_streams "${REPO_ROOT}/doc/acceptance.md"
    assert_failure
    DOC_MOVE_RECIPE=1 run _assert_realbox_doc_streams "${REPO_ROOT}/doc/acceptance.md"
    assert_failure
}

@test "acceptance 5.1 rejects unexpected diagnostics with optional prefixes (#999)" {
    _prepare_realbox_doc_stubs
    DOC_EXTRA_STDERR='[INFO] box: unexpected' run _assert_realbox_doc_streams "${REPO_ROOT}/doc/acceptance.md"
    assert_failure
    DOC_EXTRA_STDERR='[INFO] psi before unexpected' run _assert_realbox_doc_streams "${REPO_ROOT}/doc/acceptance.md"
    assert_failure
}

@test "acceptance 5.1 rejects unexpected slash text in documented output (#999)" {
    _prepare_realbox_doc_stubs
    local doc="${BATS_TEST_TMPDIR}/acceptance.md"
    sed 's/host-state kept-unknown=0$/host-state kept-unknown=0\/unexpected/' "${REPO_ROOT}/doc/acceptance.md" >"${doc}"
    run _assert_realbox_doc_streams "${doc}"
    assert_failure
}
