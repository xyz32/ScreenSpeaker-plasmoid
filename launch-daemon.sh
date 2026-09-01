#!/bin/bash
# Launch the shared speaker daemon. Its output-path lock guarantees that
# repeated launches from multiple plasmoid instances are harmless.
# Args: <log-path> <daemon-script> <device> <output-path>

set -eu
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

LOG="$1"
DAEMON="$2"
DEVICE="$3"
OUTPUT="$4"

exec >>"$LOG" 2>&1

echo "=== launcher $(date '+%F %T %Z') device=$DEVICE ==="

exec python3 "$DAEMON" \
    --daemonize \
    --log "$LOG" \
    --device "$DEVICE" \
    --output "$OUTPUT"
