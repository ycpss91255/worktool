# box/tmux-env.fish - drops a host TMUX / TMUX_PANE from the box's fish
# shells (issue #179).
#
# box/dev.ini installs this file at /etc/fish/conf.d/worktool-tmux.fish in
# the box (init hooks, on every box start); every fish in the box reads it
# at startup - the login shell `distrobox enter dev` opens included. The
# sh / bash twin, and WHY, are in box/tmux-env.sh: TMUX is kept only when it
# names a socket under the box's own TMUX_TMPDIR, dropped otherwise, and
# dropped when TMUX_TMPDIR is empty; TMUX_PANE goes with it. The prefix is
# compared as a string (not a glob), so a TMUX_TMPDIR holding glob
# characters matches only itself. Written to box/dev.ini as base64;
# test/unit/box_tmux_env_spec.bats keeps the two identical.

if set -q TMUX; or set -q TMUX_PANE
    set -l _prefix "$TMUX_TMPDIR/"
    if test -z "$TMUX_TMPDIR"; or test (string sub -l (string length -- $_prefix) -- "$TMUX") != $_prefix
        set -q TMUX; and set -eg TMUX
        set -q TMUX_PANE; and set -eg TMUX_PANE
    end
end
