# Shared property and owner tables for config mutation coverage.

_rows() {
    local _ip='unit/config_spec.bats@config_set replaces its keys in place, drops their duplicates'
    local _s4='unit/setup_spec.bats@#199 r4: every setup run'
    local _s5='unit/setup_spec.bats@#199 r5: every setup run'
    local _a4='integration/assemble_spec.bats@#199 r4: a recorded home'
    local _pres="${_ip};${_s4};${_a4}"
    local _own="${_ip};${_s5};${_a4}"
    local _cs='unit/config_spec.bats@'
    printf '%s\n' \
        "get-first|behave|get_first|=|=|${_cs}config_get reads the first occurrence" \
        "get-bare|behave|get_bare|=|=|${_cs}config_get reads the first occurrence" \
        "get-lf|behave|get_lf|=|=|${_cs}config_get reads the first occurrence" \
        "get-all|behave|get_all|=|=|${_cs}config_get_all reads every occurrence" \
        "get-all-bare|behave|get_all_bare|=|=|${_cs}config_get_all reads every occurrence;unit/config_validate_spec.bats@bare key = empty value: link" \
        "bare-validate|behave|bare_validate|=|=|unit/config_validate_spec.bats@bare key = empty value: every judged key" \
        "each-args|behave|each_args|=|=|${_cs}config_each passes line number" \
        "each-skip|behave|each_skip|=|=|${_cs}config_each passes line number" \
        "each-stop|behave|each_stop|=|=|${_cs}config_each stops at the first failing callback" \
        "exists|behave|exists|=|=|${_cs}the state file is" \
        "location|behave|location|=|=|${_cs}the state file is" \
        "log|behave|log|=|=|${_cs}config_log / config_say / config_fill" \
        "say|behave|say|=|=|${_cs}config_log / config_say / config_fill" \
        "fill|behave|fill|=|=|${_cs}config_log / config_say / config_fill" \
        "eof|render|eof|# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  \n|=|${_cs}config_set replace-only keeps;${_s5};${_a4}" \
        "blank|render|blank|# c\nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z|# c\nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\nzz=1\nyy=2\n|${_pres}" \
        "comments|render|comments|\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  |\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  \nzz=1\nyy=2\n|${_pres}" \
        "crlf|render|crlf|# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\nlink=.z\n\n  |# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\nlink=.z\n\n  \nzz=1\nyy=2\n|${_pres}" \
        "foreign-known|render|foreign_known|# c\n\n  \nhome=/new\nfuture=x\n\n  |# c\n\n  \nhome=/new\nfuture=x\n\n  \nzz=1\nyy=2\n|${_pres}" \
        "unknown|render|unknown|# c\n\n  \nhome=/new\nlink=.a\nlink=.a\nbox=dev\r\nlink=.z\n\n  |# c\n\n  \nhome=/new\nlink=.a\nlink=.a\nbox=dev\r\nlink=.z\n\n  \nzz=1\nyy=2\n|${_pres}" \
        "dup-foreign|render|dup_foreign|# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nbox=dev\r\nlink=.z\n\n  |# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nbox=dev\r\nlink=.z\n\n  \nzz=1\nyy=2\n|${_pres}" \
        "order|render|order|# c\n\n  \nhome=/new\nlink=.z\nbox=dev\r\nlink=.a\nfuture=x\nlink=.a\n\n  |# c\n\n  \nhome=/new\nlink=.z\nbox=dev\r\nlink=.a\nfuture=x\nlink=.a\n\n  \nzz=1\nyy=2\n|${_pres}" \
        "in-place|render|in_place|# c\n\n  \nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  \nhome=/new|# c\n\n  \nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  \nhome=/new\nzz=1\nyy=2\n|${_own}" \
        "dup-owned|render|dup_owned|# c\n\n  \nhome=/new\nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  |# c\n\n  \nhome=/new\nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  \nzz=1\nyy=2\n|${_own}" \
        "append-order|render|append_order|=|# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  \nyy=2\nzz=1\n|${_ip};${_s4}" \
        "append-sep|render|append_sep|=|# c\n\n  \nhome=/new\nlink=.a\nfuture=x\nlink=.a\nbox=dev\r\nlink=.z\n\n  zz=1\nyy=2\n|${_cs}config_set appending keeps every EOF framing;${_s4}" \
        "new-header|render|new_header|=|=|${_cs}config_set creates a missing file" \
        "odd-args|behave|odd_args|=|=|${_cs}config_set with an odd number of arguments" \
        "fail-nothing|behave|fail_nothing|=|=|${_cs}a failing render writes nothing" \
        "atomic|behave|atomic|=|=|${_cs}config_set replaces the file by rename" \
        "mode|behave|mode|=|=|${_cs}config_set keeps the file.s mode;unit/setup_spec.bats@r3: setup keeps the state file.s mode;integration/assemble_spec.bats@r3: assemble keeps the state file.s mode" \
        "lock|behave|lock|=|=|${_cs}two concurrent config_set calls both land" \
        "no-flock|behave|no_flock|=|=|${_cs}without flock" \
        "wa-atomic|behave|wa_atomic|=|=|${_cs}config_write_atomic replaces by rename" \
        "wa-mode|behave|wa_mode|=|=|${_cs}config_write_atomic replaces the file with stdin" \
        "owner|behave|@owner|=|=|-"
}

# The owner property, per module: module | mutant | cases. One row for every
# module of the source graph (test/helper/graph.bash, from every script
# under script/ whose graph reaches lib/config.sh) that names a public config_* function or XDG_CONFIG_HOME in
# a non-comment line; a guard fails on such a module without a row, or a row
# without such a module. Modules that name neither are not checked.
_owner_rows() {
    local _ow='unit/config_owner_spec.bats@owner: every'
    printf '%s\n' \
        "lib/link.sh|owner_link|${_ow} assemble row" \
        "lib/enter.sh|owner_enter|${_ow} setup row;${_ow} status row" \
        "lib/home.sh|owner_home|${_ow} assemble row" \
        "script/box/setup.sh|owner_setup_restore|${_ow} setup row" \
        "script/box/assemble.sh|owner_assemble_existing|${_ow} assemble row" \
        "script/box/status.sh|owner_status|${_ow} status row" \
        "script/box/bench.sh|owner_bench|${_ow} bench row"
}

