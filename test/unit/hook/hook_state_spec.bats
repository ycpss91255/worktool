#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../helper/common"

@test "every hook state guard consumer calls begin and end in its file lifecycle" {
    local spec
    while IFS= read -r -d '' spec; do
        if ! grep -Eq '^[[:space:]]*load[[:space:]]+.*hook_state' "${spec}"; then
            continue
        fi
        run awk '
            /^setup_file\(\)[[:space:]]*\{/ { lifecycle = "begin"; begin = 0 }
            /^teardown_file\(\)[[:space:]]*\{/ { lifecycle = "end"; end = 0 }
            /^\}/ { lifecycle = "" }
            /^[[:space:]]*hook_state_guard_begin[[:space:]]*$/ {
                if (lifecycle == "begin") begin = 1
            }
            /^[[:space:]]*hook_state_guard_end[[:space:]]*$/ {
                if (lifecycle == "end") end = 1
            }
            END {
                if (!begin || !end) {
                    print FILENAME ": missing explicit hook state guard lifecycle calls"
                    exit 1
                }
            }
        ' "${spec}"
        assert_success
    done < <(find "${BATS_TEST_DIRNAME}" -name '*.bats' -type f -print0)
}
