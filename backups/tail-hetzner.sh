#!/usr/bin/env bash
set -e

export HETZNER_TOKEN="${HETZNER_TOKEN:-$HCLOUD_TOKEN}"
export HCLOUD_TOKEN="${HCLOUD_TOKEN:-$HETZNER_TOKEN}"

# ── Auto-Discovery ───────────────────────────────────────────────────────────
if [ -z "$1" ]; then
    if [ -z "$HETZNER_TOKEN" ]; then
        echo "🔐 Auto-discovery requires an API token."
        echo "   Please run: export HETZNER_TOKEN=\"your_api_key\""
        echo "   Or provide the IP: ./tail-hetzner.sh <IP>"
        exit 1
    fi
    if command -v hcloud &> /dev/null; then
        echo "🔍 Searching for active Chromium build or sync server..."

        # Try finding the Beast first (compiling)
        HETZNER_IP=$(hcloud server list --selector build=chromium-beast -o json | jq -r '.[0].public_net.ipv4.ip // ""')
        
        if [ "$HETZNER_IP" != "" ] && [ "$HETZNER_IP" != "null" ]; then
            echo "✅ Found Build Beast at $HETZNER_IP"
        else
            # Try finding the Manager (syncing)
            HETZNER_IP=$(hcloud server list --selector build=chromium-manager -o json | jq -r '.[0].public_net.ipv4.ip // ""')
            if [ "$HETZNER_IP" != "" ] && [ "$HETZNER_IP" != "null" ]; then
                echo "✅ Found Sync Manager at $HETZNER_IP"
            fi
        fi

        if [ "$HETZNER_IP" = "" ] || [ "$HETZNER_IP" = "null" ]; then
            echo "❌ No active build or sync server found."
            echo "   Usage: ./tail-hetzner.sh <HETZNER_IP>"
            exit 1
        fi
    else
        echo "❌ Auto-discovery requires 'hcloud' CLI (not installed)."
        echo "   Usage: ./tail-hetzner.sh <HETZNER_IP>"
        exit 1
    fi
else
    HETZNER_IP="$1"
fi

# ── Configuration ────────────────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          -o ServerAliveInterval=60 \
          -o ServerAliveCountMax=120"

IDLE_TIMEOUT=3600  # 60 minutes

trap 'echo ""; echo "👋 Exiting tail. The build continues running on the server."; exit 0' INT

stream_logs() {
    # We use -F (capital F) to follow by filename across deletions/recreations
    ssh $SSH_OPTS root@$HETZNER_IP "tail -n 100 -F /var/log/build.log" | \
    while true; do
        IFS= read -r -t "$IDLE_TIMEOUT" line
        rc=$?
        if [[ $rc -eq 0 ]]; then
            echo "$line"
        elif [[ $rc -ge 130 ]]; then
            return 2
        elif [[ $rc -gt 128 ]]; then
            return 1
        else
            return 0
        fi
    done
}

handle_idle() {
    echo ""
    echo "⏳  No output for ${IDLE_TIMEOUT}s — Checking if build is still alive..."
    if ! ssh $SSH_OPTS root@$HETZNER_IP "pgrep -f build-docker || pgrep -f gclient > /dev/null 2>&1"; then
        echo "💀  Build process not found in process list."
        return 1
    fi
    echo "⏳  Build is alive (probably in a silent step). Reconnecting to log..."
    sleep 5
    return 1
}

echo "📡 Tailing build logs on Hetzner ($HETZNER_IP)..."
echo "👉 Press Ctrl+C to exit — it will NOT kill the background build."
echo "====================================================================================="

while true; do
    stream_logs
    rc=$?
    if [[ $rc -eq 0 ]]; then
        echo ""
        echo "✅ Log stream ended (build finished or server shut down)."
        break
    elif [[ $rc -ge 2 ]]; then
        break
    else
        handle_idle || true
    fi
done
