#!/usr/bin/env bash
# Source discriminator for the long-job hook; read after hook_read_input.
# Implementer CLI rust-v0.160.0 PreToolUse includes turn_id; Claude omits it.
# core/src/tools/handlers/unified_exec/exec_command.rs:520-531 forwards only
# {command} as shell tool_input, without timeout. Its outer runner bounds jobs.
hook_implementer_input() {
    [[ "$(hook_field 'has("turn_id")')" == true ]]
}
