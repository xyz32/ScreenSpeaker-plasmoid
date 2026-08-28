#!/bin/bash
# Launch the speaker-daemon detached.
# Args: <log-path> <daemon-script> <device> <output-path>

set +e
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

LOG="$1"
DAEMON="$2"
DEVICE="$3"
OUTPUT="$4"

exec >>"$LOG" 2>&1

echo "=== launcher $(date '+%F %T %Z') device=$DEVICE ==="

pkill -f '^python3? .*speaker-daemon\.py' >/dev/null 2>&1 || true
rm -f "$OUTPUT" "$OUTPUT.port"
sleep 0.2

exec python3 "$DAEMON" \
    --daemonize \
    --log "$LOG" \
    --device "$DEVICE" \
    --output "$OUTPUT"
