# Inject a reported cleanup failure only after the real launcher is reaped.
eval "$(declare -f _cold_pty_cleanup | sed '1s/_cold_pty_cleanup/_real_cold_pty_cleanup/')"
_cold_pty_cleanup() {
    _real_cold_pty_cleanup "$@" || return 1
    printf 'injected cleanup failure\n' >&2
    return 1
}
_wait_default_login() { return "${_login_result}"; }
