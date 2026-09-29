#!/usr/bin/env bash
# test/helper/enter_fake.bash - fake docker + fake distrobox for the in-box
# entry wrapper script/box/enter.sh (M3, issue #180).
#
# Loaded by the specs that drive enter.sh:
#   load "${BATS_TEST_DIRNAME}/../helper/enter_fake"
#
# enter_fake_install <dir> writes two executables into <dir>:
#
#   docker     answers only what enter.sh asks, driven by environment
#              variables the case sets (every call is appended to
#              $FAKE_DOCKER_CALLS, one line per call, `docker <args>`):
#                inspect ... {{.State.StartedAt}}  -> $FAKE_STARTED_AT
#                                                     (exit $FAKE_INSPECT_RC)
#                inspect ... {{.State.Running}}    -> $FAKE_RUNNING (true)
#                start <box>                       -> exit $FAKE_START_RC
#                logs -f <box>                     -> writes its PID to
#                    $FAKE_LOGS_PIDFILE, then plays $FAKE_LOGS_SCRIPT (lines
#                    `<delay>|<text>`: sleep <delay>, print <text>), then
#                    becomes `sleep 1000` IN PLACE (exec, same PID) - a
#                    follower that never ends by itself, like `docker logs
#                    -f` on a running container. A case proves cleanup by
#                    checking that PID is gone afterwards.
#   distrobox  appends `$*` to $FAKE_DISTROBOX_CALLS and prints
#              `FAKE-DISTROBOX <args>` on stdout, exit 0: what enter.sh
#              hands over to at the end.
#
# The zero value docker reports for a container that was never started is
# exported as FAKE_ZERO_STARTED_AT.

export FAKE_ZERO_STARTED_AT='0001-01-01T00:00:00Z'

enter_fake_install() {
    local _dir="$1"
    mkdir -p "${_dir}"
    cat >"${_dir}/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"${FAKE_DOCKER_CALLS:-/dev/null}"
case "$1" in
    inspect)
        case "$*" in
            *StartedAt*)
                [[ "${FAKE_INSPECT_RC:-0}" -eq 0 ]] || exit "${FAKE_INSPECT_RC}"
                printf '%s\n' "${FAKE_STARTED_AT:-0001-01-01T00:00:00Z}"
                ;;
            *Running*) printf '%s\n' "${FAKE_RUNNING:-true}" ;;
            *) exit 1 ;;
        esac
        ;;
    start) exit "${FAKE_START_RC:-0}" ;;
    logs)
        printf '%s\n' "$$" >"${FAKE_LOGS_PIDFILE:-/dev/null}"
        if [[ -n "${FAKE_LOGS_SCRIPT:-}" && -f "${FAKE_LOGS_SCRIPT}" ]]; then
            while IFS='|' read -r _delay _text; do
                sleep "${_delay}"
                printf '%s\n' "${_text}"
            done <"${FAKE_LOGS_SCRIPT}"
        fi
        exec sleep 1000
        ;;
    *) exit 1 ;;
esac
EOF
    cat >"${_dir}/distrobox" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_DISTROBOX_CALLS:-/dev/null}"
printf 'FAKE-DISTROBOX %s\n' "$*"
EOF
    chmod +x "${_dir}/docker" "${_dir}/distrobox"
}

# Write the `<delay>|<text>` lines given as arguments to $FAKE_LOGS_SCRIPT.
enter_fake_logs() {
    printf '%s\n' "$@" >"${FAKE_LOGS_SCRIPT}"
}

# 0 when the PID recorded by the fake `docker logs -f` is still alive.
enter_fake_logs_alive() {
    local _pid
    [[ -s "${FAKE_LOGS_PIDFILE}" ]] || return 1
    _pid="$(cat "${FAKE_LOGS_PIDFILE}")"
    kill -0 "${_pid}" 2>/dev/null
}
