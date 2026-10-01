#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"

@test "just agent codex launches without GitHub credentials when headless hooks are unavailable" {
    local _bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${_bin}"
    cat >"${_bin}/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${GH_ENTERPRISE_TOKEN:-}${GITHUB_ENTERPRISE_TOKEN:-}" ]]
[[ ! -e "${HOME}/.config/gh/hosts.yml" ]]
[[ ! -e "${GH_CONFIG_DIR}/hosts.yml" ]]
printf '%s\n' "$*"
STUB
    chmod +x "${_bin}/codex"
    run env PATH="${_bin}:${PATH}" GH_TOKEN=sentinel GITHUB_TOKEN=sentinel \
        GH_ENTERPRISE_TOKEN=sentinel GITHUB_ENTERPRISE_TOKEN=sentinel \
        just -f "${REPO_ROOT}/justfile" agent codex -- exec hello
    assert_success
    assert_output 'exec hello'
}
