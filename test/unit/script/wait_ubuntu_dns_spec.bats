#!/usr/bin/env bats

setup() {
    ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
    SCRIPT="${ROOT}/.agents/script/network/wait-ubuntu-dns.sh"
    TEST_BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${TEST_BIN}"
    export DNS_LOG="${BATS_TEST_TMPDIR}/dns.log"
    export PATH="${TEST_BIN}:${PATH}"
    cat > "${TEST_BIN}/getent" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$DNS_LOG"
case "${DNS_MODE:-success}:$2" in
    fail:security.ubuntu.com) exit 2 ;;
    hang:security.ubuntu.com) sleep 10 ;;
esac
STUB
    cat > "${TEST_BIN}/child" <<'STUB'
#!/usr/bin/env bash
[[ $1 == 'a b' && $2 == '*' ]] || exit 99
exit 37
STUB
    chmod +x "${TEST_BIN}/getent" "${TEST_BIN}/child"
}

@test "checks all hosts and preserves command arguments and exit status" {
    run "$SCRIPT" --attempts 1 --interval 0 --timeout 1 -- child 'a b' '*'
    [ "$status" -eq 37 ]
    [ "$(cat "$DNS_LOG")" = "$(printf '%s\n' archive.ubuntu.com security.ubuntu.com ports.ubuntu.com)" ]
}

@test "retries all hosts and does not execute command on failure" {
    run env DNS_MODE=fail "$SCRIPT" --attempts 2 --interval 0 --timeout 1 -- touch "${BATS_TEST_TMPDIR}/ran"
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$DNS_LOG")" -eq 6 ]
    [ ! -e "${BATS_TEST_TMPDIR}/ran" ]
}

@test "bounds a hanging lookup" {
    run env DNS_MODE=hang timeout 5 "$SCRIPT" --attempts 1 --timeout 1 -- touch "${BATS_TEST_TMPDIR}/ran"
    [ "$status" -eq 1 ]
    [ ! -e "${BATS_TEST_TMPDIR}/ran" ]
    [[ "$output" == *"failed to resolve security.ubuntu.com"* ]]
    [ "$(wc -l < "$DNS_LOG")" -eq 3 ]
}

@test "validates arguments and provides help" {
    run "$SCRIPT" --timeout 0 -- :
    [ "$status" -eq 2 ]
    run "$SCRIPT" --unknown
    [ "$status" -eq 2 ]
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
}

@test "help validates wrapper options but does not parse command arguments" {
    run "$SCRIPT" --help --bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown option '--bogus'"* ]]
    run "$SCRIPT" --help --attempts nope
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid value 'nope'"* ]]
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    run "$SCRIPT" --attempts 1 --interval 0 --timeout 1 -- bash -c 'exit 37' -- --help --bogus
    [ "$status" -eq 37 ]
}
