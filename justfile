# justfile - worktool user interface entry (auto-discovered by `just`).
#
# `just` IS the interface, modelled on ycpss91255-docker/base
# (ADR-00000005/10/11): zero special cases - every action is a namespace
# declared with `mod?` below and nothing else lives at this level; the
# namespaces are action-named (test, box; never ci/cd); bare `just <ns>`
# runs the most (`just test` = everything CI runs) and sub-recipes only
# narrow; every recipe is a thin forwarder that hands its arguments to the
# script under script/<ns>/ verbatim - ALL validation, usage text and
# --help live in those scripts. Bare `just` lists the namespaces.
#
# The doc comment above each `mod?` is what `just --list` shows for it.

# Self-test: lint + bats tiers in Docker (just test [build|lint|unit|matrix|integration|system|system-real|acceptance|selfcheck])
mod? test 'script/test/justfile.test'
# Dev box lifecycle: just box assemble [--dry-run] [--file X] | bench [--runs N] [--max-ms N] [--json] | setup [--auto-enter yes|no ...] | status | enter [--box N] [-- CMD]  (M3 adds rm)
mod? box 'script/box/justfile.box'
# Agent launch without GitHub authentication (headless fallback).
mod? agent 'script/agent/justfile.agent'

# Cleanup merged linked worktrees (dry-run by default).
mod? worktree '.agents/script/worktree/justfile.worktree'

# Default: list the namespaces.
default:
    @just --list
