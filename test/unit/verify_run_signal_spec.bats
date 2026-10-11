#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    export SIGNAL_STATE="${BATS_TEST_TMPDIR}"
    cat >"${SIGNAL_STATE}/child" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
trap 'sleep 0.2; echo finished >>"${SIGNAL_STATE}/events"; exit 0' INT TERM HUP
printf '%s\n' "$$" >"${SIGNAL_STATE}/child.pid"
touch "${SIGNAL_STATE}/ready"
sleep 3
echo finished >>"${SIGNAL_STATE}/events"
CHILD
    chmod +x "${SIGNAL_STATE}/child"
    cat >"${SIGNAL_STATE}/caller" <<'CALLER'
#!/usr/bin/env bash
set -euo pipefail
source "${LIB_DIR}/verify_run.sh"
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'echo cleanup >>"${SIGNAL_STATE}/events"' EXIT
_just() { (verify_run 10 "${SIGNAL_STATE}/child"); }
_just
CALLER
}

signal_caller() {
    node - "$1" "${SIGNAL_STATE}/caller" <<'JS'
const {spawn} = require('child_process');
const fs = require('fs');
const p = spawn('bash', [process.argv[3]], {detached: true, stdio: 'inherit'});
const deadline = Date.now() + 5000;
const timer = setInterval(() => {
    if (fs.existsSync(process.env.SIGNAL_STATE + '/ready')) {
        clearInterval(timer);
        process.kill(-p.pid, 'SIG' + process.argv[2]);
    } else if (Date.now() > deadline) {
        clearInterval(timer);
        process.kill(-p.pid, 'SIGKILL');
    }
}, 10);
const watchdog = setTimeout(() => process.kill(-p.pid, 'SIGKILL'), 6000);
p.on('exit', (code, signal) => {
    clearInterval(timer);
    clearTimeout(watchdog);
    console.log('rc=' + (code === null ? signal : code));
});
JS
}

assert_signal_cleanup() {
    run signal_caller "$1"
    assert_success
    assert_output "rc=$2"
    run cat "${SIGNAL_STATE}/events"
    assert_output $'finished\ncleanup'
    local pid
    read -r pid <"${SIGNAL_STATE}/child.pid"
    ! kill -0 "${pid}" 2>/dev/null
}

teardown() {
    local pid
    if [[ -f "${SIGNAL_STATE}/child.pid" ]]; then
        read -r pid <"${SIGNAL_STATE}/child.pid"
        if kill -0 "${pid}" 2>/dev/null; then
            kill -KILL "${pid}"
        fi
    fi
}

@test "verify_run: INT waits for the child before caller cleanup and exits 130" {
    assert_signal_cleanup INT 130
}
