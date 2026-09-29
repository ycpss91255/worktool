# box/tmux-env.sh - drops a host TMUX / TMUX_PANE from the box's sh / bash
# login shells (issue #179).
#
# box/dev.ini installs this file at /etc/profile.d/worktool-tmux.sh in the
# box (init hooks, on every box start); /etc/profile sources it in every
# sh / bash login shell. Its fish twin is box/tmux-env.fish.
#
# WHY: `distrobox enter` copies the caller's environment into the box.
# Entered from a HOST tmux pane, TMUX names the host server's socket on the
# /tmp the box shares with the host, and tmux prefers the socket in $TMUX
# over the box's TMUX_TMPDIR. The first line of defence is on the host:
# `just box setup` keeps a block in distrobox's own config that drops
# TMUX / TMUX_PANE before distrobox-enter copies the environment
# (lib/enter.sh enter_distrobox_conf_body), for every entry path. This file
# is the second line, inside the box, for a run that did not read that
# config (a different XDG_CONFIG_HOME, a config the user removed): the
# login shell drops them once, for everything it starts. TMUX is kept only
# when it names a socket under the box's own TMUX_TMPDIR (a pane of the
# box's own server); TMUX_PANE goes with it.
#
# Sourced, not executed: no `set`, no `exit` (it must not change or end the
# login shell). POSIX sh. Written to box/dev.ini as base64;
# test/unit/box_tmux_env_spec.bats keeps the two identical.

if [ -z "${TMUX_TMPDIR:-}" ]; then
    unset TMUX TMUX_PANE
else
    case "${TMUX:-}" in
        "${TMUX_TMPDIR}"/*) ;;
        *) unset TMUX TMUX_PANE ;;
    esac
fi
