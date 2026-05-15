#!/usr/bin/env bash
# tools/cloud-speed-build.sh — Ad-hoc Fast Single-Version Builder
#
# STRATEGY:
# 1. Use a cheap Manager server (cx23) to perform shallow clone/setup.
# 2. Hand off to a Beast server (ccx63) for high-speed compilation of both Linux & Windows.
# 3. Shutdown Beast, attach tiny Transfer server for artifacts.
set -e

[ -z "$HETZNER_TOKEN" ] && { echo "❌ ERROR: HETZNER_TOKEN not set."; exit 1; }

VERSION="${1:-147.0.7727.138}"
VOL_NAME="chromium-mv2-src-vol"

echo "🌱 PHASE 1: Performing Shallow Clone for $VERSION (Cheap Node)..."
# Using --setup-only ensures we stay on the cheap Manager seed for the 30GB clone.
./build-hetzner.sh "$VERSION" --target all --setup-only

echo "🚀 PHASE 2: Launching Build ($VERSION, Linux + Windows)..."
# This starts the Manager which then hands off to the Beast.
./build-hetzner.sh "$VERSION" --target all --keep-volume

echo "🔍 Waiting for Beast to spin up..."
BEAST_IP=""
while [ -z "$BEAST_IP" ]; do
    sleep 20
    BEAST_IP=$(hcloud server list --selector "build=chromium-beast" -o noheader -o columns=public_net.ipv4.ip | head -n 1)
done
echo "🎯 Beast identified at: $BEAST_IP"

echo "📋 Tailing logs from Beast (Building Linux then Windows)..."
echo "   (This will take ~2.5 - 3 hours. Press Ctrl+C to stop tailing; the build will continue.)"
# We tail the log until we see the final success message
ssh -o StrictHostKeyChecking=no root@$BEAST_IP "tail -f /var/log/build.log" | tee /tmp/build.log | sed '/✅ SUCCESS/q'

if grep -q "✅ SUCCESS" /tmp/build.log; then
    echo "🎉 Build Finished Successfully!"
else
    echo "❌ Build might have failed or was interrupted. Check logs at root@$BEAST_IP:/var/log/build.log"
    exit 1
fi

echo "🧹 PHASE 3: Shutting down Beast, keeping Volume..."
hcloud server delete "$BEAST_IP"

echo "📦 PHASE 4: Attaching cheap Transfer server..."
hcloud server create --name "transfer-node" --type "cx23" --image "ubuntu-22.04" --location "hel1" --ssh-key "$(hcloud ssh-key list -o noheader -o columns=name | head -n 1)"
sleep 20
TRANS_IP=$(hcloud server describe "transfer-node" -o json | jq -r .public_net.ipv4.ip)
VOL_ID=$(hcloud volume describe "$VOL_NAME" -o json | jq -r .id)

hcloud volume attach "$VOL_NAME" --server "transfer-node"
sleep 10

echo "🔧 Preparing Transfer Node (installing zstd)..."
ssh -o StrictHostKeyChecking=no root@$TRANS_IP "apt-get update && apt-get install -y zstd"

echo "🚚 Downloading Linux artifacts (Streaming Zstd)..."
ssh -o StrictHostKeyChecking=no root@$TRANS_IP "mkdir -p /mnt/chromium && mount /dev/disk/by-id/scsi-0HC_Volume_$VOL_ID /mnt/chromium && cd /mnt/chromium/src/out/linux && tar -I 'zstd -T2' -cf - *.deb" > linux-$VERSION.tar.zst

echo "🚚 Downloading Windows artifacts (Streaming Zstd)..."
ssh -o StrictHostKeyChecking=no root@$TRANS_IP "cd /mnt/chromium/src/out/win && tar -I 'zstd -T2' -cf - *.exe" > win-$VERSION.tar.zst

echo "✅ DONE. Artifacts saved locally:"
ls -lh linux-$VERSION.tar.zst win-$VERSION.tar.zst
echo "👉 RUN: hcloud server delete transfer-node"
