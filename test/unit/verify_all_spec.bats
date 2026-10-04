#!/usr/bin/env bats
# test/unit/verify_all_spec.bats - script/verify/all.sh cannot false-pass (M3, #182)
#
# WHAT THIS PROVES
#   script/verify/all.sh is the one line the maintainer runs to verify every
#   non-real-machine acceptance group of doc/acceptance.md: ui, gate, setup,
#   diagram, evidence, in that order (realbox is excluded - it needs
#   --allow-real-box on a real host). It must:
#
#     - run the five groups in order, with no argument each;
#     - never run realbox;
#     - stop at the first group that fails, even when that group printed
#       plausible output, and exit non-zero (1 for a failure, 3 when the
#       group could not run here - never 0);
#     - print one summary line per group it ran and a final verdict;
#     - treat a group script that is missing from the checkout as a failure,
#       never as a skip.
#
# HOW
#   The degraded-copy method of this branch's verify specs: the REAL all.sh
#   is copied into a throwaway script/verify/ under BATS_TEST_TMPDIR next to
#   six STUB group scripts. Each stub records its name and argument count,
#   prints a plausible expected-output line, and exits the status the case
#   gives it. So every case differs from the control in exactly one way,
#   and no real group (Docker, gh, distrobox) ever runs.

load "${BATS_TEST_DIRNAME}/../helper/common"

@test "verify scripts enable errexit per ADR 0001" {
    local _script
    for _script in all ui diagram evidence; do
        run grep -Fx 'set -euo pipefail' "${REPO_ROOT}/script/verify/${_script}.sh"
        assert_success
    done
}

@test "CI: test-unit and verify-all checkouts fetch full history for scope acceptance" {
    local _job
    # test-unit is a matrix leg of the gate job, sharing its checkout.
    for _job in gate verify-all; do
        run awk -v job="${_job}" '
            /^  [[:alnum:]_-]+:$/ { in_job = ($0 == "  " job ":") }
            in_job && /^      - / { checkout = 0; with_options = 0 }
            in_job && /^        uses: actions\/checkout@/ { checkout = 1 }
            checkout && /^        with:$/ { with_options = 1; next }
            checkout && /^        [^ ]/ { with_options = 0 }
            in_job && checkout && with_options && /^          fetch-depth:/ {
                print $2
            }
        ' "${REPO_ROOT}/.github/workflows/ci.yml"
        assert_success
        assert_equal "${_job} checkout fetch-depth: ${output}" \
            "${_job} checkout fetch-depth: 0"
    done
}

@test "acceptance: PR 157 scope includes verification, product support and tests" {
    local _scope _path
    _scope="$(sed -n '/^本 PR(#157)/p' "${REPO_ROOT}/doc/acceptance.md")"
    run printf '%s\n' "${_scope}"
    for _path in 'doc/acceptance.md' 'doc/design.md' 'doc/enter.md' \
        'doc/manifest.md' 'doc/evidence/' 'ADR 0008' '0010' \
        'script/verify/' 'justfile' 'lib/config_backup.sh' 'lib/guard.sh' \
        'lib/distrobox_manager.sh' 'lib/home.sh' 'test/unit/enter_spec.bats' \
        'script/test/test.sh' 'test/unit/verify_*_spec.bats' \
        'test/unit/justfile_spec.bats' 'test/unit/fixture/' 'test/helper/' \
        'test/system/real_engine_spec.bats'; do
        assert_output --partial "${_path}"
    done
    refute_output --partial '不動產品程式'
    refute_output --partial '要驗的產品程式全在 main'
}

# Match only listed code paths (exact, directory or glob), or a listed ADR
# number for files in doc/adr/. Prose mentioning a path is not coverage.
_scope_covers_path() {
    local _scope="$1" _path="$2" _entry _number
    while IFS= read -r _entry; do
        if [[ "${_path}" == @(${_entry}) ]]; then
            return 0
        fi
        if [[ "${_entry}" == */ && "${_path}" == "${_entry}"* ]]; then
            return 0
        fi
    done < <(printf '%s\n' "${_scope}" | grep -oE "\`[^\`]+\`" | tr -d '`')
    if [[ "${_path}" =~ ^doc/adr/([0-9]{4})-[^/]+\.md$ ]]; then
        _number="${BASH_REMATCH[1]}"
        [[ "${_scope}" =~ ADR[[:space:]]+[0-9]{4}(／[0-9]{4})* ]] || return 1
        [[ "／${BASH_REMATCH[0]#ADR }／" == *"／${_number}／"* ]] && return 0
    fi
    return 1
}

# Docker runs as root while CI's checkout belongs to the runner user.
# Trust only this checkout, without changing persistent Git configuration.
_scope_git() {
    git -c safe.directory="${REPO_ROOT}" -C "${REPO_ROOT}" "$@"
}

@test "acceptance: PR 157 scope covers every real changed path relative to main" {
    local _main _head _scope _path _missing="" _changed
    if _scope_git rev-parse --verify 'origin/main^{commit}' >/dev/null 2>&1; then
        _main=origin/main
    elif _scope_git rev-parse --verify 'main^{commit}' >/dev/null 2>&1; then
        _main=main
    else
        skip 'no main ref resolves'
    fi
    _head="$(_scope_git rev-parse HEAD)"
    [[ "${_head}" != "$(_scope_git rev-parse "${_main}")" ]] \
        || skip 'HEAD is the main ref itself'
    # This frozen scope belongs to PR 157, not to branches after its merge.
    if _scope_git cat-file -e "${_main}:script/verify" 2>/dev/null; then
        skip 'main already contains PR 157 verification'
    fi
    _scope="$(sed -n '/^本 PR(#157)/p' "${REPO_ROOT}/doc/acceptance.md")"
    run _scope_git diff --name-only "${_main}...HEAD"
    assert_success
    _changed="${output}"
    while IFS= read -r _path; do
        [[ -n "${_path}" ]] || continue
        if ! _scope_covers_path "${_scope}" "${_path}"; then
            _missing+="${_path}"$'\n'
        fi
    done <<<"${_changed}"
    if [[ -n "${_missing}" ]]; then
        printf 'Paths missing from PR 157 scope:\n%s' "${_missing}" >&2
        return 1
    fi
}

@test "acceptance: later PR skips PR 157 scope once main contains verification" {
    local _repo="${BATS_TEST_TMPDIR}/later-pr" _spec
    mkdir -p "${_repo}/test/unit" "${_repo}/test/helper" \
        "${_repo}/script/verify" "${_repo}/doc" "${_repo}/.claude/workflows"
    _spec="${_repo}/test/unit/verify_all_spec.bats"
    cp "${BATS_TEST_FILENAME}" "${_spec}"
    cp "${REPO_ROOT}/test/helper/common.bash" "${_repo}/test/helper/"
    cp "${REPO_ROOT}/script/verify/all.sh" "${_repo}/script/verify/"
    sed -n '/^本 PR(#157)/p' "${REPO_ROOT}/doc/acceptance.md" \
        >"${_repo}/doc/acceptance.md"
    git -C "${_repo}" init -q -b main
    git -C "${_repo}" config user.name 'Scope test'
    git -C "${_repo}" config user.email '1+scope-test@users.noreply.github.com'
    git -C "${_repo}" add .
    git -C "${_repo}" commit -qm 'Merge PR 157 acceptance'
    git -C "${_repo}" update-ref refs/remotes/origin/main HEAD
    git -C "${_repo}" checkout -qb later-pr
    printf 'later PR change\n' >"${_repo}/.claude/workflows/pr-loop.js"
    git -C "${_repo}" add .
    git -C "${_repo}" commit -qm 'Change workflow in a later PR'

    # Exercise the actual scope case against a real post-merge Git history.
    run bats --formatter tap --filter 'every real changed path' "${_spec}"
    assert_success
    assert_output --partial '# skip main already contains PR 157 verification'
}

setup() {
    COPY="${BATS_TEST_TMPDIR}/copy"
    mkdir -p "${COPY}/script/verify"
    cp "${REPO_ROOT}/script/verify/all.sh" "${COPY}/script/verify/all.sh"
    ALL_SH="${COPY}/script/verify/all.sh"
    export STUB_CALLS="${BATS_TEST_TMPDIR}/stub.calls"
    : >"${STUB_CALLS}"
    local _g
    for _g in ui gate setup diagram realbox evidence; do
        _stub_group "${_g}" 0
    done
}

# _stub_group <group> <rc>: the copy's <group>.sh records `<group>.sh <argc>`
# to $STUB_CALLS, prints a plausible expected-output line on stdout and a
# progress line on stderr, and exits <rc>.
_stub_group() {
    local _g="$1" _rc="$2"
    cat >"${COPY}/script/verify/${_g}.sh" <<EOF
#!/usr/bin/env bash
printf '%s.sh %s\n' "${_g}" "\$#" >>"\${STUB_CALLS}"
printf '[INFO] item of ${_g} PASSED\n' >&2
printf '${_g}-output-ok\n'
exit ${_rc}
EOF
    chmod +x "${COPY}/script/verify/${_g}.sh"
}

_stub_calls() {
    cat "${STUB_CALLS}"
}

# --- Control -----------------------------------------------------------------

@test "control: every group passes -> exit 0, groups run in order with no argument, realbox never" {
    run "${ALL_SH}"
    assert_success
    assert_equal "$(_stub_calls)" "$(printf '%s\n' 'ui.sh 0' 'gate.sh 0' 'setup.sh 0' \
        'diagram.sh 0' 'evidence.sh 0')"
    assert_line 'ui-output-ok'
    assert_line 'evidence-output-ok'
}

@test "control: one summary line per group and a PASS verdict naming realbox as not run" {
    run "${ALL_SH}"
    assert_success
    assert_line 'verify all: ui PASS'
    assert_line 'verify all: gate PASS'
    assert_line 'verify all: setup PASS'
    assert_line 'verify all: diagram PASS'
    assert_line 'verify all: evidence PASS'
    assert_line 'verify all: VERDICT PASS (5/5 groups: ui gate setup diagram evidence; realbox not run - it needs --allow-real-box on a real host)'
    refute_output --partial 'FAIL'
}

# --- Failures: plausible output, non-zero exit ------------------------------

@test "gate exits 1 after printing plausible output -> exit 1, stops there, FAIL verdict" {
    _stub_group gate 1
    run "${ALL_SH}"
    assert_failure 1
    assert_equal "$(_stub_calls)" "$(printf '%s\n' 'ui.sh 0' 'gate.sh 0')"
    assert_line 'gate-output-ok'
    assert_line 'verify all: ui PASS'
    assert_line 'verify all: gate FAIL (rc=1)'
    refute_line --partial 'verify all: setup'
    assert_line 'verify all: VERDICT FAIL at gate (rc=1); passed: ui; not run: setup diagram evidence'
}

@test "the first group failing stops everything after it" {
    _stub_group ui 1
    run "${ALL_SH}"
    assert_failure 1
    assert_equal "$(_stub_calls)" "ui.sh 0"
    assert_line 'verify all: VERDICT FAIL at ui (rc=1); passed: none; not run: gate setup diagram evidence'
}

@test "the last group failing still fails the run" {
    _stub_group evidence 1
    run "${ALL_SH}"
    assert_failure 1
    assert_line 'verify all: evidence FAIL (rc=1)'
    assert_line 'verify all: VERDICT FAIL at evidence (rc=1); passed: ui gate setup diagram; not run: none'
    refute_line --partial 'VERDICT PASS'
}

@test "a group that cannot run here (rc 3, UNAVAILABLE) exits 3, never 0" {
    _stub_group setup 3
    run "${ALL_SH}"
    assert_failure 3
    assert_line 'verify all: setup UNAVAILABLE (rc=3)'
    assert_line 'verify all: VERDICT FAIL at setup (rc=3); passed: ui gate; not run: diagram evidence'
}

@test "any other non-zero group status (2, 124) is a failure with exit 1" {
    local _rc
    for _rc in 2 124; do
        : >"${STUB_CALLS}"
        _stub_group diagram "${_rc}"
        run "${ALL_SH}"
        assert_failure 1
        assert_line "verify all: diagram FAIL (rc=${_rc})"
    done
}

@test "a group script missing from the checkout is a failure, not a skip" {
    rm "${COPY}/script/verify/gate.sh"
    run "${ALL_SH}"
    assert_failure 1
    assert_equal "$(_stub_calls)" "ui.sh 0"
    assert_output --partial 'gate.sh'
    assert_line --partial 'verify all: VERDICT FAIL at gate'
}

@test "a group script that is not executable is a failure, not a skip" {
    chmod -x "${COPY}/script/verify/setup.sh"
    run "${ALL_SH}"
    assert_failure 1
    assert_line --partial 'verify all: VERDICT FAIL at setup'
    refute_line --partial 'VERDICT PASS'
}

@test "a failing realbox is irrelevant: it is never run" {
    _stub_group realbox 1
    run "${ALL_SH}"
    assert_success
    refute_output --partial 'realbox.sh'
    run grep -c realbox "${STUB_CALLS}"
    assert_output 0
}

# --- CLI contract ------------------------------------------------------------

@test "--help exits 0, names the five groups and the realbox exclusion, runs nothing" {
    run "${ALL_SH}" --help
    assert_success
    assert_output --partial 'Usage: all.sh'
    assert_output --partial 'ui gate setup diagram evidence'
    assert_output --partial 'realbox'
    assert_equal "$(_stub_calls)" ""
}

@test "--list prints the five groups in order, runs nothing" {
    run "${ALL_SH}" --list
    assert_success
    assert_equal "${output}" "$(printf '%s\n' ui gate setup diagram evidence)"
    assert_equal "$(_stub_calls)" ""
}

@test "an unknown option exits 2 naming it, runs nothing" {
    run "${ALL_SH}" --bogus
    assert_failure 2
    assert_line "all.sh: unknown option '--bogus' (see --help)"
    assert_equal "$(_stub_calls)" ""
}

@test "a positional argument exits 2, runs nothing (all takes no ITEM)" {
    run "${ALL_SH}" 1.1
    assert_failure 2
    assert_line "all.sh: unexpected argument '1.1' (see --help)"
    assert_equal "$(_stub_calls)" ""
}

@test "real diagram and evidence missing tools aggregate as UNAVAILABLE with exit 3" {
    local _group _tool _bash _stripped="${BATS_TEST_TMPDIR}/minimal-path"
    _bash="$(command -v bash)"
    mkdir -p "${_stripped}" "${COPY}/lib"
    for _tool in bash dirname; do
        ln -s "$(command -v "${_tool}")" "${_stripped}/${_tool}"
    done
    mkdir -p "${COPY}/box"
    cp "${REPO_ROOT}/box/dev.ini" "${COPY}/box/dev.ini"
    for _tool in guard log manifest; do
        cp "${REPO_ROOT}/lib/${_tool}.sh" "${COPY}/lib/"
    done
    for _group in diagram evidence; do
        cp "${REPO_ROOT}/script/verify/${_group}.sh" "${COPY}/script/verify/"
        PATH="${_stripped}" run "${_bash}" "${ALL_SH}"
        assert_failure 3
        assert_line "verify all: ${_group} UNAVAILABLE (rc=3)"
        refute_line "verify all: ${_group} FAIL (rc=1)"
        refute_output --partial 'VERDICT PASS'
        _stub_group "${_group}" 0
    done
}

@test "every verify group reports an exact missing-tool line and exits 3 through just" {
    local _group _tool _needed _path _just _item _real
    _just="$(command -v just)"
    for _group in ui gate setup diagram evidence realbox; do
        case "${_group}" in
            ui) _tool="grep"; _item=1.1 ;;
            gate) _tool="grep"; _item=2.1 ;;
            setup) _tool="sed"; _item=3.1 ;;
            diagram) _tool="grep"; _item=4.1 ;;
            evidence) _tool="gh"; _item=6.1 ;;
            realbox) _tool="distrobox"; _item=5.1 ;;
        esac
        _path="${BATS_TEST_TMPDIR}/without-${_group}-${_tool}"
        mkdir -p "${_path}"
        for _needed in bash sh dirname env just timeout grep sort wc sed find mktemp \
            docker gh jq awk cut tee date uname mkdir ln distrobox; do
            [[ "${_needed}" == "${_tool}" ]] && continue
            # Some verification tools are absent from the unit image. An
            # executable that fails keeps those unrelated guards satisfied
            # and prevents any verification work if a guard is bypassed.
            _real="$(command -v "${_needed}")" || _real=/bin/false
            ln -s "${_real}" "${_path}/${_needed}"
        done
        if [[ "${_group}" == realbox ]]; then
            run env PATH="${_path}" "${_just}" --justfile "${REPO_ROOT}/justfile" verify "${_group}" --allow-real-box "${_item}"
        else
            run env PATH="${_path}" "${_just}" --justfile "${REPO_ROOT}/justfile" verify "${_group}" "${_item}"
        fi
        assert_failure 3
        assert_line "[UNAVAILABLE] ${_group}.sh: ${_tool} not found on PATH"
    done
}
