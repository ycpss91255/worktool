# Streams are captured separately. Only their own ordering is meaningful:
# stderr proves the final stage failed; stdout proves its TAP is busy-only.
FILENAME == ARGV[1] { runner_line(); next }
{ tap_line() }

function runner_line() {
    if (in_log) {
        if ($0 == "[system-real] --- end of dockerd log") in_log = 0
        return
    }
    if ($0 ~ /^\[ci\] acceptance bats OK$/) ready = 1
    if ($0 ~ /^\[ci\] Running system-real bats /) {
        if (!ready || active) bad = 1
        active = 1
        return
    }
    if ($0 ~ /^\[ci\] ERROR:/) {
        if ($0 != "[ci] ERROR: system-real bats failed" || !active) bad = 1
        errors++
        return
    }
    if (!active) return
    if ($0 ~ /^\[system-real\] --- dockerd log \(tail\): / && errors == 1) {
        in_log = 1
        return
    }
    if ($0 ~ /^error: [Rr]ecipe .* failed.*exit code 1$/ ||
        $0 ~ /^\[system-real\] stopping nested dockerd \(pid [0-9]+\)$/ ||
        $0 ~ /^\[system-real\] cleanup: (containers left in the nested daemon: 0|box .* still present - removing)$/) return
    if (!errors && $0 ~ /^\[ci\]   required specs OK \([0-9]+ case\(s\) declared by [0-9]+ file\(s\)\)$/) return
    if ($0 != "") bad = 1
}

function finish_case() {
    if (failed && (!latency || !status3 || !busy)) bad = 1
}

function tap_line(    line, number) {
    if ($0 ~ /^1\.\.[0-9]+$/) {
        finish_case()
        if (plan && (count != plan || failures || skipped)) bad = 1
        plan = substr($0, 4) + 0
        if (!plan) bad = 1
        count = failed = failures = skipped = 0
        return
    }
    if ($0 ~ /^(not )?ok [0-9]+ /) {
        finish_case()
        failed = ($0 ~ /^not ok /)
        status3 = busy = 0
        line = $0
        sub(/^(not )?ok /, "", line)
        number = line + 0
        sub(/^[0-9]+ /, "", line)
        count++
        if (number != count || !plan || count > plan) bad = 1
        if (line ~ /# skip/) skipped = 1
        latency = (line == "real engine: bench.sh --box dev --runs 5 --warmup 2 --shell \047fish -c exit\047 --max-ms ENTER_MAX_MS exits 0 (enter-latency gate on fish) and prints the enter, shell and inbox metric lines" ||
                   line == "real engine: bench.sh --box dev --runs 1 --warmup 0 --shell \047fish -c exit\047 --max-ms 1 exits 1 with the threshold message (the gate bites on a real box)")
        if (failed) failures++
        return
    }
    if (failed && $0 ~ /^# (status : 3|actual   : 3)$/) status3 = 1
    if (failed && $0 ~ /^# (output *: |  )?\[ERROR\] host too busy (to measure|mid-run) \(inconclusive\): .*re-run when idle$/) busy = 1
    if ($0 !~ /^#/ && $0 != "") bad = 1
}

END {
    finish_case()
    exit !(active && plan > 0 && count == plan && failures > 0 &&
           errors == 1 && !in_log && !skipped && !bad)
}
