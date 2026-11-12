#!/usr/bin/env bash
# Exercise the real bench and public enter with one heavy first enter.
set -euo pipefail
name="${0##*/}"
case "${name}" in
    just)
        case "${2:-}" in
            bench | enter) exec "${FAKE_BOX_SCRIPTS}/$2.sh" "${@:3}" ;;
        esac
        ;;
    distrobox)
        if [[ "${1:-}" == enter ]]; then
            if [[ ! -e "${FAKE_STATE_DIR}/started" ]]; then
                : >"${FAKE_STATE_DIR}/started"
                printf 'some avg10=9.00 avg60=0.00 avg300=0.00 total=1\n' >"${BENCH_PSI_FILE}"
            fi
            if [[ "$*" == *EPOCHREALTIME* ]]; then printf '1000\n'; fi
            exit 0
        fi
        ;;
    docker)
        # A started engine fixture delegates initialisation to distrobox enter.
        printf '2026-10-17T00:00:00Z\n'
        exit 0
        ;;
    sleep)
        if [[ "$*" == 1 ]]; then
            printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"${BENCH_PSI_FILE}"
            printf 'quiet-poll\n' >>"${FAKE_STATE_DIR}/quiet-polls"
            exit 0
        fi
        exec /bin/sleep "$@"
        ;;
esac
exec "${FAKE_STATE_DIR}/fallback/${name}" "$@"
