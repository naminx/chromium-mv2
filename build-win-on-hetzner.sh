#!/usr/bin/env bash
set -e

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./build-win-on-hetzner.sh <HETZNER_IP> <CHROMIUM_VERSION>"
    echo "  (Auto-destruct is intentionally NOT supported because you must SCP the .exe file afterwards!)"
    exit 1
fi

HETZNER_IP="$1"
CHROMIUM_VERSION="$2"

# Ephemeral servers: don't pollute ~/.ssh/known_hosts or show "Permanently added" warnings.
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

echo "====================================================================="
echo "🚨 CRITICAL REMINDER BEFORE PROCEEDING 🚨"
echo "We are about to rsync your local Chromium-mv2 directory (excluding .git/ and out/)"
echo "to the Hetzner server. This includes the 1.3GB Windows SDK toolchain zip."
echo "Make sure your patches are saved locally!"
echo "====================================================================="
echo "Targeting Windows Build Chromium Version: $CHROMIUM_VERSION"
echo "If this looks correct, press Enter to blast off! (Ctrl+C to abort)"
read -p "..."

echo "🚀 Connecting to Hetzner to prepare environment..."
ssh $SSH_OPTS root@$HETZNER_IP "mkdir -p /root/chromium-mv2"

echo "🚀 Synchronizing files (this may take a minute for the 1.3GB toolchain zip)..."
# Exclude git, build artifacts, and existing exes from transferring
rsync -a -e "ssh $SSH_OPTS" --info=progress2 \
    --exclude='.git*' \
    --exclude='out' \
    --exclude='*.exe' \
    ./ root@$HETZNER_IP:/root/chromium-mv2/

echo "🚀 Configuring the build environment..."

# SSH into the server and pipe the entire installation and build process
ssh $SSH_OPTS root@$HETZNER_IP << EOF
    set -e

    echo "⚙️ Setting up 16GB Swap Space..."
    if [ ! -f /swapfile ]; then
        fallocate -l 16G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo "✅ Swap space created and enabled."
    else
        echo "✅ Swap file already exists."
    fi

    echo "📦 Checking for Docker installation..."
    if ! command -v docker &> /dev/null; then
        echo "Docker not found. Installing now..."
        apt-get update >/dev/null
        apt-get install -y docker.io >/dev/null
    fi

    echo "🏗️ Preparing autonomous detached build script..."
    cat << 'INNERSCRIPT' > /root/autonomous_build.sh
#!/usr/bin/env bash

echo "======================================"
echo "Starting Windows Chromium Build at \$(date)"
echo "======================================"

cd /root/chromium-mv2
if ./build-docker.sh "$CHROMIUM_VERSION"; then
    echo "🎉 SUCCESS: The Windows Chromium binary has been successfully cross-compiled!"
    echo "It is located at /root/chromium-mv2/mini_installer-${CHROMIUM_VERSION}.exe"
else
    echo "❌ BUILD FAILED!"
fi
INNERSCRIPT

    chmod +x /root/autonomous_build.sh

    echo "🚀 Launching autonomous Windows build in the background (nohup)..."
    nohup /root/autonomous_build.sh > /var/log/build.log 2>&1 &

    echo "====================================================================="
    echo "✅ The compiler has been successfully detached and is running!"
    echo "You can now safely close your laptop or press Ctrl+C without killing the build."
    echo "To monitor the build progress at any time, run:"
    echo "👉 ./tail-hetzner.sh $HETZNER_IP"
    echo ""
    echo "🛑 IMPORTANT: When finished, you must MANUALLY download the .exe by running:"
    echo "scp -r root@$HETZNER_IP:/root/chromium-mv2/mini_installer-${CHROMIUM_VERSION}.exe ./"
    echo "Then delete the server from the Hetzner dashboard manually!"
    echo "====================================================================="
EOF
