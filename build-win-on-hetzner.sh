#!/usr/bin/env bash
# build-win-on-hetzner.sh — Cross-compile Chromium for Windows on a Hetzner Ubuntu server.
#
# Usage:
#   ./build-win-on-hetzner.sh <HETZNER_IP> <CHROMIUM_VERSION>
#   ./build-win-on-hetzner.sh 1.2.3.4 146.0.7680.80
#
# This script:
#   1. Rsyncs local patches + toolchain zip to the Hetzner server
#   2. Installs Docker (with correct ulimit and FUSE support)
#   3. Launches build-docker.sh in a detached nohup session
#   4. Prints an SCP command to download the resulting .exe

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
echo "We are about to rsync your local chromium-mv2 directory (excluding .git/ and out/)"
echo "to the Hetzner server. This includes the 1.3GB Windows SDK toolchain zip."
echo "Make sure your patches are saved locally!"
echo "====================================================================="
echo "Targeting Windows Build → Chromium Version: $CHROMIUM_VERSION"
echo "If this looks correct, press Enter to blast off! (Ctrl+C to abort)"
read -p "..."

echo "🚀 Preparing remote directory on Hetzner..."
ssh $SSH_OPTS root@$HETZNER_IP "mkdir -p /root/chromium-mv2"

echo "🚀 Synchronizing files (this may take a minute for the 1.3GB toolchain zip)..."
# Exclude git history, build artifacts, and previously built .exe files from transfer.
rsync -a -e "ssh $SSH_OPTS" --info=progress2 \
    --exclude='.git*' \
    --exclude='out' \
    --exclude='*.exe' \
    ./ root@$HETZNER_IP:/root/chromium-mv2/

echo "🚀 Configuring build environment on Hetzner..."

# ── Fix 1: Pass CHROMIUM_VERSION into the remote setup session.
# The outer heredoc is unquoted (no quotes around EOF) so $CHROMIUM_VERSION
# expands HERE on the local machine and is baked into the remote commands.
# The INNERSCRIPT heredoc uses a QUOTED delimiter ('INNERSCRIPT') to prevent
# a second round of expansion — so we write the expanded version explicitly
# with sed substitution below.
ssh $SSH_OPTS root@$HETZNER_IP << EOF
    set -e

    echo "⚙️ Setting up Swap Space (2× RAM, max 16 GB)..."
    if [ ! -f /swapfile ]; then
        # Scale swap to 2× physical RAM, capped at 16 GB.
        # This prevents a fixed 16 GB swap from consuming 40% of the disk on
        # small sanity-check servers (e.g. CX32 with 80 GB disk, 8 GB RAM).
        RAM_GB=\$(awk '/MemTotal/{printf "%d", \$2/1024/1024}' /proc/meminfo)
        SWAP_GB=\$(( RAM_GB * 2 ))
        [ "\$SWAP_GB" -gt 16 ] && SWAP_GB=16
        [ "\$SWAP_GB" -lt 4 ]  && SWAP_GB=4
        echo "   RAM: \${RAM_GB} GB → allocating \${SWAP_GB} GB swap"
        fallocate -l "\${SWAP_GB}G" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo "✅ Swap space (\${SWAP_GB} GB) created and enabled."
    else
        echo "✅ Swap file already exists."
    fi

    # ── Fix 2: Ensure FUSE is available for the ciopfs mount inside Docker.
    echo "🔧 Loading fuse kernel module..."
    modprobe fuse 2>/dev/null || true
    # Ensure /dev/fuse is accessible by the Docker daemon (runs as root here, so fine).
    if [ ! -c /dev/fuse ]; then
        mknod /dev/fuse c 10 229 2>/dev/null || true
    fi
    chmod 666 /dev/fuse 2>/dev/null || true

    echo "📦 Checking for Docker installation..."
    if ! command -v docker &> /dev/null; then
        echo "Docker not found. Installing now..."
        # Use error-visible apt-get (no output suppression so failures are visible)
        apt-get update
        apt-get install -y docker.io
        # ── Fix 3: Start and enable the Docker daemon after install.
        systemctl enable --now docker
        echo "✅ Docker installed and daemon started."
    else
        # Daemon may not be running even if docker binary is present.
        systemctl start docker 2>/dev/null || true
        echo "✅ Docker already installed."
    fi

    # ── Fix 4: Give the Docker daemon a high fd limit so --ulimit nofile=65536
    # inside build-docker.sh is actually honoured.
    # Without this, the systemd-managed daemon may be capped at 1024 fds,
    # causing the --ulimit flag to be silently rejected or capped.
    mkdir -p /etc/docker
    DAEMON_JSON_NEEDED=false
    if [ ! -f /etc/docker/daemon.json ]; then
        DAEMON_JSON_NEEDED=true
    elif ! grep -q '"nofile"' /etc/docker/daemon.json 2>/dev/null; then
        DAEMON_JSON_NEEDED=true
    fi
    if [ "\$DAEMON_JSON_NEEDED" = "true" ]; then
        cat > /etc/docker/daemon.json << 'DAEMONJSON'
{
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  }
}
DAEMONJSON
        echo "✅ Docker daemon.json written with nofile=65536."
        systemctl restart docker
        echo "✅ Docker daemon restarted."
    else
        echo "✅ Docker daemon.json already has nofile limit."
    fi

    echo "🏗️ Preparing autonomous detached build script..."
    # ── Fix 1 (continued): Write CHROMIUM_VERSION as a literal value into the
    # autonomous_build.sh script using printf, not a heredoc, so the shell
    # variable is expanded NOW (on the remote, where EOF already expanded it)
    # and stored as a hard-coded string in the script file.
    # This avoids the bug where a single-quoted heredoc delimiter would embed
    # the literal text "\$CHROMIUM_VERSION" (undefined at runtime).
    printf '%s\n' '#!/usr/bin/env bash' \
        '' \
        'echo "======================================"' \
        'echo "Starting Windows Chromium Build at \$(date)"' \
        'echo "======================================"' \
        '' \
        'cd /root/chromium-mv2' \
        "if ./build-docker.sh \"$CHROMIUM_VERSION\"; then" \
        '    echo "🎉 SUCCESS: The Windows Chromium binary has been successfully cross-compiled!"' \
        "    echo \"It is located at /root/chromium-mv2/mini_installer-${CHROMIUM_VERSION}.exe\"" \
        'else' \
        '    echo "❌ BUILD FAILED!"' \
        '    exit 1' \
        'fi' \
        > /root/autonomous_build.sh

    chmod +x /root/autonomous_build.sh

    echo "🚀 Launching autonomous Windows build in the background (nohup)..."
    nohup /root/autonomous_build.sh > /var/log/build.log 2>&1 &

    echo "====================================================================="
    echo "✅ The compiler has been successfully detached and is running!"
    echo "You can now safely close your laptop or press Ctrl+C without killing the build."
    echo "To monitor the build progress at any time, run:"
    echo "👉 ./tail-hetzner.sh $HETZNER_IP"
    echo ""
    echo "🛑 IMPORTANT: When finished, download the .exe by running:"
    echo "   scp $SSH_OPTS root@$HETZNER_IP:/root/chromium-mv2/mini_installer-${CHROMIUM_VERSION}.exe ./"
    echo "Then delete the server from the Hetzner dashboard manually!"
    echo "====================================================================="
EOF
