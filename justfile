# justfile - worktool user interface entry (auto-discovered by `just`).
#
# `just` IS the interface, modelled on ycpss91255-docker/base
# (ADR-00000005/10/11): zero special cases - every action is a namespace
# declared with `mod?` below and nothing else lives at this level; the
# namespaces are action-named (test, box, verify, agent, worktree, job;
# never ci/cd). Bare `just test` runs everything CI runs; bare `just verify`
# lists checks without running them. Sub-recipes narrow the scope; every recipe is a thin forwarder that hands its arguments to the
# script under script/<ns>/ verbatim - ALL validation, usage text and
# --help live in those scripts. Bare `just` lists the namespaces.
#
# The doc comment above each `mod?` is what `just --list` shows for it.

# Self-tests in Docker; just --list test lists its recipes.
mod? test 'script/test/justfile.test'
# Dev box lifecycle; just --list box lists its recipes.
mod? box 'script/box/justfile.box'
# Acceptance checks; just --list verify lists its recipes.
mod? verify 'script/verify/justfile.verify'
# Agent launch without GitHub authentication; just --list agent lists its recipes.
mod? agent 'script/agent/justfile.agent'

# Cleanup merged linked worktrees (dry-run by default); just --list worktree lists its recipes.
mod? worktree '.agents/script/worktree/justfile.worktree'


# Detached agent jobs and compact results; just --list job lists its recipes.
mod? job '.agents/script/justfile.job'

# Default: list the namespaces.
default:
    @just --list
