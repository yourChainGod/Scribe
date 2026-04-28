#!/usr/bin/env bash
#
# gen_perf_samples.sh
#   Generate 1 MB / 5 MB / 20 MB plain-text fixtures for the
#   performance test target. Re-runnable; existing files are
#   regenerated only when --force is passed.
#
#   We don't commit the binaries; ScribeTests/PerformanceTests.swift
#   bails gracefully if the fixtures aren't there. That keeps the
#   repo lean while letting anyone reproduce the measurement.
#
# `yes | head` will exit 141 (SIGPIPE) under `set -o pipefail` because
# `yes` is killed once `head` closes its read end — that's the
# *intended* shutdown path, not a real failure. Stick with -eu only.
set -eu

DIR="$(cd "$(dirname "$0")/.." && pwd)/Tests/Fixtures"
mkdir -p "$DIR"

force=false
[[ "${1:-}" == "--force" ]] && force=true

# Lorem ipsum line ~80 bytes including newline. Repeat to target size.
LINE='Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor.'
LINE_LEN=$(( ${#LINE} + 1 ))   # +1 for the newline

generate () {
    local target_mb=$1
    local file="$DIR/perf_${target_mb}mb.txt"
    if [[ -f "$file" && "$force" != "true" ]]; then
        echo "skip   $(basename "$file") (exists)"
        return
    fi
    local target_bytes=$(( target_mb * 1024 * 1024 ))
    local lines=$(( (target_bytes + LINE_LEN - 1) / LINE_LEN ))
    : > "$file"
    # `yes` + head is the fastest portable way to splat a fixed line.
    yes "$LINE" | head -n "$lines" > "$file"
    actual=$(stat -f%z "$file")
    printf "wrote  %-20s %10d bytes  (≈ %d MB)\n" \
        "$(basename "$file")" "$actual" "$target_mb"
}

generate 1
generate 5
generate 20

echo
echo "Fixtures live in: $DIR"
echo "Run:  swift test --filter PerformanceTests"
