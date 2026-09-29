#!/usr/bin/env bats
# test/system/real_assemble_spec.bats - real distrobox assemble, system tier (M2)
#
# WHAT THIS PROVES
#   The delivered manifest (box/dev.ini) is parsed by the REAL, pinned
#   distrobox (baked into the test image, see dockerfile/Dockerfile.test and
#   ${DISTROBOX_VERSION}) into the expected container-manager create request:
#   the wrapper `script/box/assemble.sh` runs in real (non-dry-run) mode, real
#   `distrobox assemble create` -> real `distrobox-create` run, and the
#   request that actually reaches the container manager carries container
#   name `dev`, image `ubuntu:26.04`, and the manifest's additional_packages
#   (`ripgrep fzf tmux fish` - M3, issue #160, adds tmux and fish as the
#   auto-enter prerequisite), which distrobox hands to its in-container
#   entrypoint (distrobox-init) as `--additional-packages`. A manager
#   failure on `create` propagates back through the wrapper as a non-zero
#   exit.
#
# HOW (no docker-in-docker)
#   The container manager is a FAKE: test/system/fixture/fake_container_manager.sh
#   is symlinked onto PATH as `docker` (first) and selected via
#   DBX_CONTAINER_MANAGER=docker. It answers the probes distrobox makes
#   (ps / inspect / pull / create), records every invocation PER ARGUMENT
#   (NUL-delimited argv files + a calls.log index), fails loudly on anything
#   unexpected, and can inject a `create` failure (FAKE_CM_FAIL_CREATE=1).
#
# WHAT THIS DOES NOT PROVE (see doc/manifest.md)
#   - that ubuntu:26.04 can actually be pulled,
#   - that ripgrep/fzf/tmux/fish actually install inside the box
#     (distrobox-init never runs here - no container is ever started),
#   - that the resulting box is usable (`distrobox enter dev -- rg --version`).
#   Those need a real container manager and are proven by the real-engine
#   group of this tier, test/system/real_engine_spec.bats, which runs in the
#   docker-in-docker runner (test.sh --system-real). This shim group stays
#   the fast, daemon-free half.

load "${BATS_TEST_DIRNAME}/../helper/common"

setup() {
    ASSEMBLE="${REPO_ROOT}/script/box/assemble.sh"
    SHIM="${REPO_ROOT}/test/system/fixture/fake_container_manager.sh"

    # Fake manager first on PATH, under the name distrobox will resolve.
    SHIMBIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${SHIMBIN}"
    ln -s "${SHIM}" "${SHIMBIN}/docker"
    PATH="${SHIMBIN}:${PATH}"

    # Per-argument recording target for the shim.
    CM_LOG="${BATS_TEST_TMPDIR}/cm-log"
    mkdir -p "${CM_LOG}"
    export FAKE_CM_LOG_DIR="${CM_LOG}"

    # Hermetic distrobox environment: a fresh HOME (no ~/.distroboxrc, no
    # cache), the fake manager selected explicitly, and no desktop entry
    # generation (that path needs `docker cp` and is out of scope here).
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    export DBX_CONTAINER_MANAGER=docker
    export DBX_CONTAINER_GENERATE_ENTRY=0
}

# --- helpers over the shim's per-argument log --------------------------------

# Print the argv file of the single recorded call whose subcommand is $1.
# Fails if that subcommand was recorded zero or more than one time.
_argv_file_of() {
    local _sub="$1" _seq
    local _matches=()
    while IFS= read -r _seq; do
        _matches+=("${_seq}")
    done < <(awk -v s="${_sub}" '$2 == s { print $1 }' "${CM_LOG}/calls.log")
    [[ "${#_matches[@]}" -eq 1 ]] \
        || fail "expected exactly one '${_sub}' call, got ${#_matches[@]}"
    printf '%s/%s.argv\n' "${CM_LOG}" "${_matches[0]}"
}

# Load a NUL-delimited argv file into the global ARGV array (one element per
# argument, empty arguments preserved).
_load_argv() {
    ARGV=()
    mapfile -d '' ARGV <"$1"
}

# Print the index of the first ARGV element equal to $1; fail if absent.
_index_of() {
    local _i
    for _i in "${!ARGV[@]}"; do
        if [[ "${ARGV[${_i}]}" == "$1" ]]; then
            printf '%s\n' "${_i}"
            return 0
        fi
    done
    fail "argument '$1' not found in recorded argv"
}

# Count ARGV elements equal to $1.
_count_of() {
    local _i _n=0
    for _i in "${!ARGV[@]}"; do
        [[ "${ARGV[${_i}]}" == "$1" ]] && _n=$((_n + 1))
    done
    printf '%s\n' "${_n}"
}

# Trim leading/trailing whitespace from $1.
_trim() {
    local _s="$1"
    _s="${_s#"${_s%%[![:space:]]*}"}"
    printf '%s' "${_s%"${_s##*[![:space:]]}"}"
}

# --- preflight: the real, pinned distrobox is what runs ----------------------

@test "the real pinned distrobox is installed in the test image" {
    [[ -n "${DISTROBOX_VERSION:-}" ]] \
        || fail "DISTROBOX_VERSION not set - this tier runs inside the test image only"
    run command -v distrobox
    assert_success
    run distrobox --version
    assert_success
    assert_output "distrobox: ${DISTROBOX_VERSION}"
}

@test "the fake container manager is the docker that will be resolved" {
    run command -v docker
    assert_success
    assert_output "${SHIMBIN}/docker"
    # Unsupported requests must fail loudly, never read as success.
    run docker frobnicate
    assert_failure 2
    assert_output --partial "unsupported subcommand 'frobnicate'"
}

# --- (a) upstream parser check: distrobox's own dry-run ----------------------

@test "upstream: distrobox assemble --dry-run parses box/dev.ini into a create with name dev / image ubuntu:26.04" {
    cd "${REPO_ROOT}"
    run distrobox assemble create --dry-run --file box/dev.ini
    assert_success
    assert_line --partial " - Creating dev..."
    # distrobox-assemble hands distrobox-create the parsed fields; its dry-run
    # prints the container-manager create command it would run.
    assert_line --partial "docker create"
    assert_line '--name "dev"'
    assert_line "ubuntu:26.04"
    assert_line --regexp '^--additional-packages " *ripgrep fzf tmux fish"$'
}

# --- real mode: the create request that reached the manager -----------------

@test "real assemble: the create request reaching the manager carries name dev, image ubuntu:26.04 and the manifest packages" {
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_success
    # distrobox-create's own success line: the real upstream code ran to
    # completion against the fake manager.
    assert_output --partial "Distrobox 'dev' successfully created."

    # Exactly one create request reached the manager; load its argv.
    local _create
    _create="$(_argv_file_of create)"
    _load_argv "${_create}"
    assert_equal "${ARGV[0]}" "create"

    # Container name: the first --name is docker's (the second one, after the
    # image, is distrobox-init's --name <user>).
    local _name_i
    _name_i="$(_index_of --name)"
    assert_equal "${ARGV[$((_name_i + 1))]}" "dev"

    # Image: positioned right after `--entrypoint /usr/bin/entrypoint`, i.e.
    # the container image docker would create from.
    local _ep_i
    _ep_i="$(_index_of --entrypoint)"
    assert_equal "${ARGV[$((_ep_i + 1))]}" "/usr/bin/entrypoint"
    local _image_i=$((_ep_i + 2))
    assert_equal "${ARGV[${_image_i}]}" "ubuntu:26.04"

    # additional_packages: distrobox does NOT pass them to docker; it hands
    # them to its entrypoint (distrobox-init) as `--additional-packages`
    # AFTER the image. Assert exactly one such flag, after the image, whose
    # value (whitespace-trimmed - distrobox pads it) is the manifest's list.
    assert_equal "$(_count_of --additional-packages)" "1"
    local _pkg_i
    _pkg_i="$(_index_of --additional-packages)"
    assert [ "${_pkg_i}" -gt "${_image_i}" ]
    assert_equal "$(_trim "${ARGV[$((_pkg_i + 1))]}")" "ripgrep fzf tmux fish"

    # It is a distrobox-managed container.
    local _label_i
    _label_i="$(_index_of --label)"
    assert_equal "${ARGV[$((_label_i + 1))]}" "manager=distrobox"
}

# Issue #179: distrobox bind-mounts the host's /tmp into the box, so a
# `tmux` in the box would find the HOST server's default socket
# (/tmp/tmux-<uid>/default) and attach to it. box/dev.ini gives the box
# its own TMUX_TMPDIR (a container env, so every process in the box - any
# shell, any `distrobox enter dev -- tmux` - inherits it) and an init hook
# that creates that directory as the box user on every start: tmux falls
# back to /tmp SILENTLY when TMUX_TMPDIR does not exist.
@test "#179: the create request gives the box its own TMUX_TMPDIR and init hooks that create it as the box user and install the tmux guard" {
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_success
    local _create
    _create="$(_argv_file_of create)"
    _load_argv "${_create}"

    # A container env (before the image, so it is docker's, not
    # distrobox-init's), under the box's own directory - ${HOME} expanded
    # at create time, never the shared /tmp.
    local _ep_i _env_i _found=""
    _ep_i="$(_index_of --entrypoint)"
    for _env_i in "${!ARGV[@]}"; do
        [[ "${_env_i}" -lt "${_ep_i}" && "${ARGV[${_env_i}]}" == "--env" ]] || continue
        [[ "${ARGV[$((_env_i + 1))]}" == TMUX_TMPDIR=* ]] || continue
        _found="${ARGV[$((_env_i + 1))]}"
    done
    assert_equal "${_found}" "TMUX_TMPDIR=${HOME}/dev-box/.cache/tmux"

    # The init hook goes to distrobox-init (after the image) as the words
    # after its `--`, which distrobox-init evals as the box's root on every
    # start: it creates the directory as the box user, mode 0700. The
    # expected text is literal - the variables are distrobox-init's and the
    # container's, expanded there, never here.
    local _dd_i _want
    _dd_i="$(_index_of --)"
    assert [ "${_dd_i}" -gt "$((_ep_i + 1))" ]
    assert_equal "$((_dd_i + 2))" "${#ARGV[@]}"
    _want=": ; setpriv --reuid=\"\${container_user_uid}\" --regid=\"\${container_user_gid}\""
    _want+=" --clear-groups mkdir -p -m 0700 \"\${TMUX_TMPDIR}\""
    # ... and then moves the packaged tmux aside (dpkg-divert, codex round 2
    # on PR #232) and installs the box's tmux guard (box/tmux-guard.sh, codex
    # round 1) AT /usr/bin/tmux, byte for byte: a TMUX inherited from a host
    # tmux pane must not reach the host server, even via a path-typed
    # /usr/bin/tmux. The real binary goes OFF PATH, and the box's login
    # shells (sh / bash, fish) drop a host TMUX themselves, so running the
    # real binary directly does not reach the host either (codex round 3).
    _want+=" && mkdir -p /usr/libexec/worktool"
    _want+=" && dpkg-divert --local --rename --divert /usr/libexec/worktool/tmux --add /usr/bin/tmux"
    _want+=" && echo $(base64 -w0 <"${REPO_ROOT}/box/tmux-guard.sh")"
    _want+=" | base64 -d >/usr/bin/tmux && chmod 0755 /usr/bin/tmux"
    _want+=" && echo $(base64 -w0 <"${REPO_ROOT}/box/tmux-env.sh")"
    _want+=" | base64 -d >/etc/profile.d/worktool-tmux.sh && chmod 0644 /etc/profile.d/worktool-tmux.sh"
    _want+=" && mkdir -p /etc/fish/conf.d"
    _want+=" && echo $(base64 -w0 <"${REPO_ROOT}/box/tmux-env.fish")"
    _want+=" | base64 -d >/etc/fish/conf.d/worktool-tmux.fish && chmod 0644 /etc/fish/conf.d/worktool-tmux.fish"
    assert_equal "$(_trim "${ARGV[$((_dd_i + 1))]}")" "${_want}"
}

@test "real assemble: the manifest image is what distrobox asks the manager to pull, before create" {
    cd "${REPO_ROOT}"
    run "${ASSEMBLE}"
    assert_success

    local _pull
    _pull="$(_argv_file_of pull)"
    _load_argv "${_pull}"
    assert_equal "${ARGV[0]}" "pull"
    assert_equal "${ARGV[$((${#ARGV[@]} - 1))]}" "ubuntu:26.04"

    # Sequence: pull was requested before create.
    local _pull_line _create_line
    _pull_line="$(awk '$2 == "pull" { print NR }' "${CM_LOG}/calls.log")"
    _create_line="$(awk '$2 == "create" { print NR }' "${CM_LOG}/calls.log")"
    assert [ "${_pull_line}" -lt "${_create_line}" ]
}

# --- (b) manager failure propagates -----------------------------------------

@test "real assemble: a manager create failure propagates as a non-zero wrapper exit" {
    cd "${REPO_ROOT}"
    FAKE_CM_FAIL_CREATE=1 run "${ASSEMBLE}"
    assert_failure
    # Upstream's own failure line: the failure came from the manager, through
    # distrobox-create, through the wrapper - not from manifest validation.
    assert_output --partial "failed to create container"
    refute_output --partial "successfully created"
    # The create request did reach the manager (validation passed); it was
    # the manager that refused it.
    local _create
    _create="$(_argv_file_of create)"
    assert [ -f "${_create}" ]
}
