#!/bin/bash
# Read and filter logs by bootstrap_room

BOOTSTRAP_ROOM="${1:-}"

echo "=========================================="
echo "Prefill-2 Log (last 50 lines)"
echo "=========================================="
if [ -n "$BOOTSTRAP_ROOM" ]; then
    echo "Filtering by bootstrap_room: $BOOTSTRAP_ROOM"
    grep -A 10 -B 5 "$BOOTSTRAP_ROOM" /tmp/sglang-prefill-2.log | tail -50
else
    tail -50 /tmp/sglang-prefill-2.log
fi

echo ""
echo "=========================================="
echo "Decode-1 Log (last 50 lines)"
echo "=========================================="
if [ -n "$BOOTSTRAP_ROOM" ]; then
    echo "Filtering by bootstrap_room: $BOOTSTRAP_ROOM"
    grep -A 10 -B 5 "$BOOTSTRAP_ROOM" /tmp/sglang-decode-1.log | tail -50
else
    tail -50 /tmp/sglang-decode-1.log
fi
