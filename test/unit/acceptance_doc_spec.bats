#!/usr/bin/env bats
# shellcheck source-path=SCRIPTDIR
# Keep the acceptance skip policy aligned with the runner (#988).
load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    RUNNER="${BATS_TEST_TMPDIR}/runner"
    DOC="${BATS_TEST_TMPDIR}/acceptance"
    STRUCTURE="${BATS_TEST_TMPDIR}/structure"
    ADR="${BATS_TEST_TMPDIR}/adr"
    cp "${LIB_DIR}/test_shard.sh" "${RUNNER}"
    cp "${LIB_DIR}/log.sh" "${BATS_TEST_TMPDIR}/log.sh"
    cp "${BATS_TEST_DIRNAME}/../../doc/acceptance.md" "${DOC}"
    cp "${BATS_TEST_DIRNAME}/../../doc/structure.md" "${STRUCTURE}"
    cp "${BATS_TEST_DIRNAME}/../../doc/adr/0016-ci-unit-shards-union-verdict.md" "${ADR}"
}

_section() {
    awk '/^  - \[ \] 2\.1 / { inside=1 } /^  - \[ \] 2\.2 / { inside=0 } inside' "$1"
}

_compare_exemptions() {
    local runner="$1" doc="$2" dir="$3" name reason rc
    # Accept only the known predicate shape, then exercise its actual behavior.
    awk '
        /^test_shard_has_unexpected_skip\(\)/ { inside=1 }
        inside && /(^|[^[:alnum:]_])next([^[:alnum:]_]|$)/ { next_count++ }
        inside && /reason = " # skip/ { split($0, a, "\""); reason=substr(a[2], 2); reasons++ }
        inside && /if \(tier == "unit" && stress != "1" &&/ { predicate++ ; names_on=1; next }
        inside && names_on && /\$0 == "[^"]+" reason/ {
            split($0, a, "\""); names[++n]=a[2]
            if ($0 ~ /\)\) next/) names_on=0
            next
        }
        inside && names_on { bad=1 }
        inside && /^}/ { if (predicate != 1 || reasons != 1 || next_count != 1 || bad || names_on || !n) exit 1
            for (i=1; i<=n; i++) print names[i] "\t" reason; found=1; exit }
        END { if (!found) exit 1 }
    ' "${runner}" >"${dir}/raw.rows" || return 1
    LC_ALL=C sort "${dir}/raw.rows" >"${dir}/runner.rows"
    _section "${doc}" | awk -F '`' '/^      \| `/ { print $2 "\t" $4 }' | LC_ALL=C sort >"${dir}/doc.rows"
    [[ -s "${dir}/runner.rows" && -s "${dir}/doc.rows" ]] || return 1
    [[ "$(uniq -d "${dir}/runner.rows")" == '' && "$(uniq -d "${dir}/doc.rows")" == '' ]] || return 1
    diff -u "${dir}/runner.rows" "${dir}/doc.rows" || return 1
    # shellcheck source=../../lib/test_shard.sh
    source "${runner}"
    printf 'ok 1 unrelated case # skip unrelated reason\n' >"${dir}/tap"
    rc=0; WORKTOOL_STRESS=0 test_shard_has_unexpected_skip unit "${dir}/tap" || rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    while IFS=$'\t' read -r name reason; do
        printf 'ok 1 %s %s\n' "${name}" "${reason}" >"${dir}/tap"
        rc=0; WORKTOOL_STRESS=0 test_shard_has_unexpected_skip unit "${dir}/tap" || rc=$?
        [[ "${rc}" -eq 1 ]] || return 1
        rc=0; WORKTOOL_STRESS=1 test_shard_has_unexpected_skip unit "${dir}/tap" || rc=$?
        [[ "${rc}" -eq 0 ]] || return 1
        rc=0; WORKTOOL_STRESS=0 test_shard_has_unexpected_skip matrix "${dir}/tap" || rc=$?
        [[ "${rc}" -eq 0 ]] || return 1
        printf 'ok 1 %s\n' "${name}" >"${dir}/tap"
        rc=0; WORKTOOL_STRESS=0 test_shard_has_unexpected_skip unit "${dir}/tap" || rc=$?
        [[ "${rc}" -eq 1 ]] || return 1
        printf 'ok 1 %s %s changed\n' "${name}" "${reason}" >"${dir}/tap"
        rc=0; WORKTOOL_STRESS=0 test_shard_has_unexpected_skip unit "${dir}/tap" || rc=$?
        [[ "${rc}" -eq 0 ]] || return 1
    done <"${dir}/runner.rows"
}

_check_commands() {
    local doc="$1" rows="$2" line pattern spec name reason selected matched commands=0
    _section "${doc}" | sed -n '/^      WORKTOOL_STRESS=1 just test unit .* --filter '\''/s/^      //p' >"${BATS_TEST_TMPDIR}/commands"
    : >"${BATS_TEST_TMPDIR}/selected"
    while IFS= read -r line; do
        spec="${line#*just test unit }"; spec="${spec%% *}"
        pattern="${line#*--filter \'}"; pattern="${pattern%\'}"
        [[ -f "${BATS_TEST_DIRNAME}/../../${spec}" ]] || return 1
        selected=0; matched=''
        while IFS= read -r name; do
            if [[ "${name}" =~ ${pattern} ]]; then selected=$((selected + 1)); matched="${name}"; fi
        done < <(sed -n 's/^@test "\(.*\)" {$/\1/p' "${BATS_TEST_DIRNAME}/../../${spec}")
        [[ "${selected}" -eq 1 ]] || return 1
        grep -qF "${matched}"$'\t' "${rows}" || return 1
        printf '%s\n' "${matched}" >>"${BATS_TEST_TMPDIR}/selected"
        commands=$((commands + 1))
    done <"${BATS_TEST_TMPDIR}/commands"
    [[ "${commands}" -eq "$(wc -l <"${rows}")" && "${commands}" -gt 0 ]] || return 1
    [[ "$(LC_ALL=C sort "${BATS_TEST_TMPDIR}/selected" | uniq -d)" == '' ]]
}

_check_structure() {
    local count word
    count="$(wc -l <"$1")"
    case "${count}" in
        1) word=一 ;; 2) word=二 ;; 3) word=三 ;; 4) word=四 ;; 5) word=五 ;;
        6) word=六 ;; 7) word=七 ;; 8) word=八 ;; 9) word=九 ;; 10) word=十 ;;
        *) return 1 ;;
    esac
    grep -qF "例外僅限 unit 的${word}個具名 CPU 負載重現案例" "$2" || return 1
    grep -qF "且 \`WORKTOOL_STRESS\` 不為 \`1\`、skip 原因完全相符時才允許；設為 \`1\` 時必須執行" "$2"
}

_check_structure_names() {
    local rows="$1" structure="$2" dir="$3" bt=$'\x60'
    awk -v bt="${bt}" '/案例為 / { text=substr($0, index($0, "案例為 ")+length("案例為 ")); text=substr(text, 1, index(text, "；完整 skip")-1); n=split(text, parts, bt); for (i=2; i<=n; i+=2) print parts[i]; found++ } END { if (found != 1) exit 1 }' "${structure}" | LC_ALL=C sort >"${dir}/structure.names" || return 1
    cut -f1 "${rows}" | LC_ALL=C sort >"${dir}/runner.names"
    [[ -s "${dir}/structure.names" ]] || return 1
    [[ "$(uniq -d "${dir}/structure.names")" == '' ]] || return 1
    diff -u "${dir}/runner.names" "${dir}/structure.names"
}

_check_adr() {
    awk '/^3\. / { print; found=1 } END { if (!found) exit 1 }' "$2" >"${BATS_TEST_TMPDIR}/adr-decision" || return 1
    _check_structure "$1" "${BATS_TEST_TMPDIR}/adr-decision" || return 1
    grep -qF '整層與分片聯集共用' "${BATS_TEST_TMPDIR}/adr-decision"
}

@test "runner, acceptance table, commands and structure agree" {
    _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"
    _check_commands "${DOC}" "${BATS_TEST_TMPDIR}/runner.rows"
    _check_structure "${BATS_TEST_TMPDIR}/runner.rows" "${STRUCTURE}"
    _check_structure_names "${BATS_TEST_TMPDIR}/runner.rows" "${STRUCTURE}" "${BATS_TEST_TMPDIR}"
    _check_adr "${BATS_TEST_TMPDIR}/runner.rows" "${ADR}"
}

@test "table additions, removals, duplicates and reason changes are rejected" {
    local original="${BATS_TEST_DIRNAME}/../../doc/acceptance.md"
    sed -i '/^      | `/d' "${DOC}"
    run _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"; assert_failure
    cp "${original}" "${DOC}"
    sed -i '/^      | `/ {p;}' "${DOC}"
    run _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"; assert_failure
    cp "${original}" "${DOC}"
    sed -i '/^      | `/ {s/CPU repro/changed reason/;}' "${DOC}"
    run _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"; assert_failure
    cp "${original}" "${DOC}"
    sed -i "/^      | --- | --- |/a\\      | \`extra case\` | \`# skip extra reason\` |" "${DOC}"
    run _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"; assert_failure
}

@test "runner additions, removals and policy changes are rejected" {
    local original="${LIB_DIR}/test_shard.sh"
    sed -i "/\\\$0 == \"/ { /||/ {d;} }" "${RUNNER}"
    run _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"; assert_failure
    cp "${original}" "${RUNNER}"
    _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"
    local reason
    reason="$(cut -f2 "${BATS_TEST_TMPDIR}/runner.rows" | head -n 1)"
    awk '!changed && /\(\$0 == "/ { sub(/\(\$0 == "/, "($0 == \"extra case\" reason ||\\n                 $0 == \"" ); changed=1 } { print }' "${RUNNER}" >"${RUNNER}.new"
    mv "${RUNNER}.new" "${RUNNER}"
    # shellcheck source=../../lib/test_shard.sh
    source "${RUNNER}"
    printf 'ok 1 extra case %s\n' "${reason}" >"${BATS_TEST_TMPDIR}/tap"
    local rc=0
    WORKTOOL_STRESS=0 test_shard_has_unexpected_skip unit "${BATS_TEST_TMPDIR}/tap" || rc=$?
    [[ "${rc}" -eq 1 ]]
    run _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"; assert_failure
    cp "${original}" "${RUNNER}"
    sed -i 's/stress != "1"/stress == "1"/' "${RUNNER}"
    run _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"; assert_failure
    cp "${original}" "${RUNNER}"
    sed -i 's/CPU repro/changed reason/' "${RUNNER}"
    run _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"; assert_failure
    cp "${original}" "${RUNNER}"
    sed -i 's/\^ok \[0-9\]+ .*# skip/\^ok [0-9]+ /' "${RUNNER}"
    run _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"; assert_failure
}

@test "commands outside 2.1 and broad filters cannot hide missing or extra selections" {
    _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"
    sed -i "/^      WORKTOOL_STRESS=1 just test unit /s/--filter '[^']*'/--filter '.*'/" "${DOC}"
    run _check_commands "${DOC}" "${BATS_TEST_TMPDIR}/runner.rows"; assert_failure
    cp "${BATS_TEST_DIRNAME}/../../doc/acceptance.md" "${DOC}"
    sed -i '/^      WORKTOOL_STRESS=1 just test unit /{d;}' "${DOC}"
    printf '%s\n' "      WORKTOOL_STRESS=1 just test unit test/unit/verify_realbox_spec.bats --filter '.*'" >>"${DOC}"
    run _check_commands "${DOC}" "${BATS_TEST_TMPDIR}/runner.rows"; assert_failure
}

@test "structure count follows the derived list" {
    _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"
    sed -i 's/例外僅限 unit 的三個/例外僅限 unit 的二個/' "${STRUCTURE}"
    run _check_structure "${BATS_TEST_TMPDIR}/runner.rows" "${STRUCTURE}"; assert_failure
}

@test "an additional skip branch outside the named predicate fails closed" {
    sed -i "/if (tier == \"unit\" && stress != \"1\" \&\&/i\\            if (\$0 == \"unrelated case # skip unrelated reason\") next" "${RUNNER}"
    # Confirm the mutant actually exempts the unrelated skip.
    # shellcheck source=../../lib/test_shard.sh
    source "${RUNNER}"
    printf 'ok 1 unrelated case # skip unrelated reason\n' >"${BATS_TEST_TMPDIR}/tap"
    local rc=0
    WORKTOOL_STRESS=0 test_shard_has_unexpected_skip unit "${BATS_TEST_TMPDIR}/tap" || rc=$?
    [[ "${rc}" -eq 1 ]]
    run _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"; assert_failure
}

@test "ADR shard verdict rejects stale counts and missing opt-in policy" {
    _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"
    sed -i 's/例外僅限 unit 的三個/例外僅限 unit 的二個/' "${ADR}"
    run _check_adr "${BATS_TEST_TMPDIR}/runner.rows" "${ADR}"; assert_failure
    cp "${BATS_TEST_DIRNAME}/../../doc/adr/0016-ci-unit-shards-union-verdict.md" "${ADR}"
    sed -i 's/skip 原因完全相符時才允許/skip 均允許/' "${ADR}"
    run _check_adr "${BATS_TEST_TMPDIR}/runner.rows" "${ADR}"; assert_failure
}

@test "structure names reject missing, extra and duplicate exemptions" {
    _compare_exemptions "${RUNNER}" "${DOC}" "${BATS_TEST_TMPDIR}"
    local name bt=$'\x60' original="${BATS_TEST_DIRNAME}/../../doc/structure.md"
    name="$(cut -f1 "${BATS_TEST_TMPDIR}/runner.rows" | head -n 1)"
    NAME="${name}" awk '{ p=index($0, ENVIRON["NAME"]); if (p) $0=substr($0,1,p-1) "missing" substr($0,p+length(ENVIRON["NAME"])); print }' "${original}" >"${STRUCTURE}"
    run _check_structure_names "${BATS_TEST_TMPDIR}/runner.rows" "${STRUCTURE}" "${BATS_TEST_TMPDIR}"; assert_failure
    awk -v bt="${bt}" '/案例為 / { sub(/；完整 skip/, "、" bt "extra case" bt "；完整 skip") } { print }' "${original}" >"${STRUCTURE}"
    run _check_structure_names "${BATS_TEST_TMPDIR}/runner.rows" "${STRUCTURE}" "${BATS_TEST_TMPDIR}"; assert_failure
    NAME="${name}" awk -v bt="${bt}" '/案例為 / { sub(/；完整 skip/, "、" bt ENVIRON["NAME"] bt "；完整 skip") } { print }' "${original}" >"${STRUCTURE}"
    run _check_structure_names "${BATS_TEST_TMPDIR}/runner.rows" "${STRUCTURE}" "${BATS_TEST_TMPDIR}"; assert_failure
}
