# justfile - worktool user-facing task runner (auto-discovered by `just`).
#
# CI gates live in justfile.ci and are invoked as `just -f justfile.ci
# <recipe>` (lint / test-unit / test-integration / test-system /
# test-system-real / test-acceptance), matching init_ubuntu. This file just
# points at them so `just` with no args is self-documenting.

# Show available recipes.
default:
    @just --list

# Show the CI recipes (lint / test-unit / ... / test-acceptance / ...).
ci-help:
    @just -f justfile.ci --list

# Delegate to the CI gates for convenience.
lint:
    @just -f justfile.ci lint

test-unit:
    @just -f justfile.ci test-unit

test-integration:
    @just -f justfile.ci test-integration

test-system:
    @just -f justfile.ci test-system

# Real-engine system group (docker-in-docker, --privileged, slow).
test-system-real:
    @just -f justfile.ci test-system-real

test-acceptance:
    @just -f justfile.ci test-acceptance
