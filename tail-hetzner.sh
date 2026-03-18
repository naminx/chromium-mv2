#!/usr/bin/env bash
set -e

if [ -z "$1" ]; then
    echo "Usage: ./tail-hetzner.sh <HETZNER_IP>"
    exit 1
fi

HETZNER_IP="$1"

# ServerAliveInterval sends a keepalive every 60s so the TCP connection never
# silently drops during long, output-free steps (e.g. final link, nix eval).
# ServerAliveCountMax=120 means SSH will tolerate up to 2 hours of no response
# before giving up (60s × 120 = 7200s).
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          -o ServerAliveInterval=60 \
          -o ServerAliveCountMax=120"

# How long with no log output before we investigate.
# Set high enough that the final Chromium link step (can be 30-40 min silent)
# won't be mistaken for a stall.
IDLE_TIMEOUT=3600  # 60 minutes

stream_logs() {
    ssh $SSH_OPTS root@$HETZNER_IP "tail -n 100 -f /var/log/build.log" | \
    while true; do
        IFS= read -r -t "$IDLE_TIMEOUT" line
        rc=$?
        if [[ $rc -eq 0 ]]; then
            echo "$line"
        elif [[ $rc -gt 128 ]]; then
            # read timed out — no new log line for IDLE_TIMEOUT seconds
            return 1
        else
            # EOF — SSH connection closed cleanly
            return 0
        fi
    done
}

handle_idle() {
    echo ""
    echo "⏰  No output for ${IDLE_TIMEOUT}s — checking server..."

    # Ask the server whether autonomous_build.sh is still running.
    if ssh $SSH_OPTS root@$HETZNER_IP "pgrep -f autonomous_build.sh > /dev/null 2>&1"; then
        # Build IS still running — it's likely in a silent step (link, sign, pack).
        # Do NOT kill it. Just reconnect to the log stream.
        echo "⏳  Build is alive (probably in link/sign step). Reconnecting to log..."
        sleep 5
        # return 1 = "keep looping" so the outer while re-calls stream_logs
        return 1
    else
        # Build process is gone and log went silent — it truly stalled or crashed.
        echo "💀  Build process not found. Restarting..."
        ssh $SSH_OPTS root@$HETZNER_IP \
            "pkill -f autonomous_build.sh 2>/dev/null || true
             sleep 2
             nohup /root/autonomous_build.sh >> /var/log/build.log 2>&1 &"
        echo "🔄  Build restarted. Reconnecting in 10 seconds..."
        sleep 10
        return 1
    fi
}

echo "📡 Tailing build logs on Hetzner ($HETZNER_IP)..."
echo "👉 Press Ctrl+C to exit — it will NOT kill the background build."
echo "⏱️  SSH keepalive: every 60s  |  Idle check: after ${IDLE_TIMEOUT}s (60 min)"
echo "   (Silent steps like link/cachix-push won't trigger a restart)"
echo "====================================================================================="

while true; do
    if stream_logs; then
        # stream_logs returned 0 = clean EOF = build finished or server deleted
        echo ""
        echo "✅ Log stream ended (build finished or server shut down)."
        break
    else
        # stream_logs returned non-zero = timed out
        handle_idle || true
    fi
done
