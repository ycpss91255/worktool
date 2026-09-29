#!/bin/sh
# box/tmux-guard.sh - the dev box's `tmux` (issue #179).
#
# box/dev.ini installs this file AT /usr/bin/tmux in the box (init hooks,
# on every box start), after moving the packaged binary aside with
# dpkg-divert to /usr/libexec/worktool/tmux - off PATH, so no unguarded
# second tmux sits next to it to type or tab-complete (codex round 3 on PR
# #232). So every tmux started in the box - a bare `tmux` from any shell,
# `distrobox enter dev -- tmux`, or a path-typed /usr/bin/tmux (codex round
# 2 on PR #232) - goes through it, whatever the PATH order; a later tmux
# package upgrade lands on the diverted path and never overwrites the guard.
#
# WHY: the box has its own tmux server because box/dev.ini sets
# TMUX_TMPDIR. But tmux looks at $TMUX first, and `distrobox enter` copies
# the caller's environment into the box: entered from a HOST tmux pane,
# TMUX names the host server's socket on the /tmp the box shares with the
# host, and a `tmux` in the box would reach the HOST server. So TMUX is
# kept only when it names a socket under the box's own TMUX_TMPDIR (a pane
# of the box's own server) and dropped otherwise. With no TMUX_TMPDIR at
# all, tmux would fall back to the shared /tmp, so the guard refuses to
# run instead. The box's login shells apply the same rule to their whole
# environment (box/tmux-env.sh, box/tmux-env.fish), so the real binary run
# directly from a box shell does not see a host TMUX either.
#
# POSIX sh: the box's /bin/sh runs it. Written to box/dev.ini as base64
# (a manifest line cannot carry a script); test/unit/box_tmux_guard_spec.bats
# keeps the two identical.

case "${TMUX:-}" in
    "${TMUX_TMPDIR:?TMUX_TMPDIR is not set: refusing to use the shared /tmp}"/*) ;;
    *) unset TMUX ;;
esac
exec /usr/libexec/worktool/tmux "$@"
