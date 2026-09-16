# justfile - worktool user interface (auto-discovered by `just`).
#
# `just` IS the interface. Every recipe is a thin delegate to a script under
# script/: the Docker-only gates go through script/ci/ci.sh, the delivered
# self-check through script/selfcheck.sh, the box through
# script/assemble.sh. The scripts keep working without just
# (`./script/ci/ci.sh --unit-only` etc.); this file only adds the grammar:
#
#   just                    list recipes
#   just build              build the test image
#   just lint               ShellCheck gate
#   just test [tier]        unit | integration | system | system-real |
#                           acceptance | all (default)
#   just check              lint, then test all - exactly what CI runs
#   just selfcheck          run the delivered self-check
#   just assemble [mode] [file]
#                           mode: run (default) | dry-run;
#                           file: manifest, default box/dev.ini
#
# Every gate runs inside Docker (doc/design.md: Docker only): ci.sh builds
# the test image on demand and runs the gate in a throwaway container
# against a bind-mounted /source. `test system-real` is the ONLY privileged
# one (docker-in-docker runner, slow); `test all` runs it last.
#
# The dispatching recipes (test, assemble) validate their argument on the
# first line and only then run the delegate lines - each line is a
# separate shell, so an invalid argument never reaches a script or docker,
# and a failing tier stops the run. `just -n <recipe> [arg]` prints exactly
# the delegate calls a run would make (the tier/mode selection is resolved
# by just, not by the shell), which test/unit/justfile_spec.bats relies on.
# Must stay within what the alpine-packaged just in the test image
# (dockerfile/Dockerfile.test) and just >= 1.53 on the host both support.

set shell := ['bash', '-euo', 'pipefail', '-c']

# Show available recipes.
default:
    @just --list

# Build the test image (worktool-test:local). Optional: the gates build it on demand.
build:
    ./script/ci/ci.sh --build

# ShellCheck over all *.sh and *.bats, inside the container.
lint:
    ./script/ci/ci.sh --lint-only

# Run one test tier (unit | integration | system | system-real | acceptance) or all of them in order (system-real last).
[no-exit-message]
test tier='all':
    @case {{ quote(tier) }} in unit|integration|system|system-real|acceptance|all) ;; *) printf "just test: unknown tier '%s' (valid: unit integration system system-real acceptance all)\n" {{ quote(tier) }} >&2; exit 1 ;; esac
    {{ if tier =~ '^(unit|all)$' { './script/ci/ci.sh --unit-only' } else { '' } }}
    {{ if tier =~ '^(integration|all)$' { './script/ci/ci.sh --integration-only' } else { '' } }}
    {{ if tier =~ '^(system|all)$' { './script/ci/ci.sh --system-only' } else { '' } }}
    {{ if tier =~ '^(acceptance|all)$' { './script/ci/ci.sh --acceptance-only' } else { '' } }}
    {{ if tier =~ '^(system-real|all)$' { './script/ci/ci.sh --system-real-only' } else { '' } }}

# Lint, then every test tier in order: exactly what CI runs.
check: lint (test 'all')

# Run the delivered self-check (script/selfcheck.sh) against this checkout.
selfcheck:
    ./script/selfcheck.sh

# Assemble the dev box from a manifest (default box/dev.ini): mode run (default) or dry-run (print the distrobox command only).
[no-exit-message]
assemble mode='run' file='box/dev.ini':
    @case {{ quote(mode) }} in run|dry-run) ;; *) printf "just assemble: unknown mode '%s' (valid: run dry-run)\n" {{ quote(mode) }} >&2; exit 1 ;; esac
    {{ if mode == 'dry-run' { 'WORKTOOL_DRY_RUN=1 ' } else { '' } }}./script/assemble.sh --file {{ quote(file) }}
