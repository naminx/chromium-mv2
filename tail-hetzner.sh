#!/usr/bin/env bash
set -e

if [ -z "$1" ]; then
    echo "Usage: ./tail-hetzner.sh <HETZNER_IP>"
    exit 1
fi

HETZNER_IP="$1"

echo "📡 Tailing build logs on Hetzner ($HETZNER_IP)..."
echo "👉 Notice: Press Ctrl+C at any time to exit. It will NOT kill the background build."
echo "====================================================================================="

ssh -o StrictHostKeyChecking=accept-new root@$HETZNER_IP "tail -n 100 -f /var/log/build.log"
