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

# ── Ctrl+C handling ──────────────────────────────────────────────────────────
# Trap SIGINT (Ctrl+C) at the top level so pressing Ctrl+C anywhere in the
# script exits cleanly rather than propagating into the read/handle_idle logic.
# The background build on the server is unaffected — it's in a separate nohup
# session and is immune to signals from this local script.
trap 'echo ""; echo "👋 Exiting tail. The build continues running on the server."; exit 0' INT

stream_logs() {
    ssh $SSH_OPTS root@$HETZNER_IP "tail -n 100 -f /var/log/build.log" | \
    while true; do
        IFS= read -r -t "$IDLE_TIMEOUT" line
        rc=$?
        if [[ $rc -eq 0 ]]; then
            echo "$line"
        elif [[ $rc -ge 130 ]]; then
            # rc >= 130 means read was interrupted by a signal (128 + signal#).
            # SIGINT = 130, SIGTERM = 143, etc.
            # This is NOT a timeout — the user pressed Ctrl+C or the process
            # was signalled. Exit cleanly so the trap above can fire.
            # Return 2 as a sentinel so the outer loop can distinguish this
            # from both "clean EOF" (0) and "timed out" (1).
            return 2
        elif [[ $rc -gt 128 ]]; then
            # rc > 128 but < 130: read timed out (bash uses 142 = 128+SIGALRM
            # internally, but the manual only guarantees "> 128" for timeout).
            # No new log line for IDLE_TIMEOUT seconds — investigate.
            return 1
        else
            # rc = 1 (or any non-zero < 128): EOF — SSH connection closed cleanly.
            return 0
        fi
    done
}

handle_idle() {
    echo ""
    echo "⏰  No output for ${IDLE_TIMEOUT}s — checking server..."

    # Ask the server whether autonomous_build.sh is still running.
    # Guard the SSH call itself: if Ctrl+C fires during the pgrep check, the
    # SSH command will fail with a signal exit code — treat that as "user
    # wants to exit", not as "build not found".
    if ! ssh $SSH_OPTS root@$HETZNER_IP "pgrep -f autonomous_build.sh > /dev/null 2>&1"; then
        local pgrep_rc=$?
        if [[ $pgrep_rc -ge 130 ]]; then
            # SSH check was killed by a signal — don't mistake this for "build crashed".
            echo "⚡  Signal received during server check — not restarting."
            return 2
        fi
        # Build process is truly gone and log went silent — stalled or crashed.
        echo "💀  Build process not found. Restarting..."
        ssh $SSH_OPTS root@$HETZNER_IP \
            "pkill -f autonomous_build.sh 2>/dev/null || true
             sleep 2
             nohup /root/autonomous_build.sh >> /var/log/build.log 2>&1 &"
        echo "🔄  Build restarted. Reconnecting in 10 seconds..."
        sleep 10
        return 1
    fi

    # Build IS still running — it's in a silent step (download, link, etc.).
    # Do NOT kill it. Just reconnect to the log stream.
    echo "⏳  Build is alive (probably in a silent step). Reconnecting to log..."
    sleep 5
    # return 1 = "keep looping" so the outer while re-calls stream_logs
    return 1
}

echo "📡 Tailing build logs on Hetzner ($HETZNER_IP)..."
echo "👉 Press Ctrl+C to exit — it will NOT kill the background build."
echo "⏱️  SSH keepalive: every 60s  |  Idle check: after ${IDLE_TIMEOUT}s (60 min)"
echo "   (Silent steps like the 30GB git clone or final link won't trigger a restart)"
echo "====================================================================================="

while true; do
    stream_logs
    rc=$?
    if [[ $rc -eq 0 ]]; then
        # Clean EOF — build finished or server shut down.
        echo ""
        echo "✅ Log stream ended (build finished or server shut down)."
        break
    elif [[ $rc -ge 2 ]]; then
        # Signal (Ctrl+C) — exit cleanly. The trap will print the goodbye message.
        break
    else
        # Timed out — investigate without restarting if build is alive.
        handle_idle || true
    fi
done
