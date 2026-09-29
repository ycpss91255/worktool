# box/tmux-env.sh - drops a host TMUX from the box's sh / bash login shells
# (issue #179, codex round 3 on PR #232).
#
# box/dev.ini installs this file at /etc/profile.d/worktool-tmux.sh in the
# box (init hooks, on every box start); /etc/profile sources it in every
# sh / bash login shell - the shell `distrobox enter dev` opens. Its fish
# twin is box/tmux-env.fish.
#
# WHY: `distrobox enter` copies the caller's environment into the box.
# Entered from a HOST tmux pane, TMUX names the host server's socket on the
# /tmp the box shares with the host. box/tmux-guard.sh (the box's
# /usr/bin/tmux) drops it for `tmux`, but anything else started from the
# box shell - the real binary run directly from /usr/libexec/worktool/tmux
# included - would still inherit it and reach the HOST server. So the login
# shell drops it once, for everything it starts. The rule is the guard's:
# TMUX is kept only when it names a socket under the box's own TMUX_TMPDIR
# (a pane of the box's own server); with no TMUX_TMPDIR it is dropped.
#
# Sourced, not executed: no `set`, no `exit` (it must not change or end the
# login shell). POSIX sh. Written to box/dev.ini as base64;
# test/unit/box_tmux_guard_spec.bats keeps the two identical.

if [ -z "${TMUX_TMPDIR:-}" ]; then
    unset TMUX
else
    case "${TMUX:-}" in
        "${TMUX_TMPDIR}"/*) ;;
        *) unset TMUX ;;
    esac
fi
