#!/usr/bin/env bash
# build-hetzner.sh — Pure Infrastructure Orchestrator (Hardened)
set -e

# --- Configuration ---
VOLUME_NAME="chromium-mv2-src-vol"
VOLUME_SIZE=150
PRIMARY_LOC="hel1"
IMAGE="ubuntu-22.04"

usage() {
    echo "Usage: $0 <VERSION> --target <deb|win> [options]"
    echo ""
    echo "Environment Variables (Required):"
    echo "  HCLOUD_TOKEN        Hetzner Cloud API Token"
    echo "  GITHUB_TOKEN        GitHub Personal Access Token"
    echo ""
    echo "Options:"
    echo "  --cleanup             Nuclear: Delete ALL build servers and volumes"
    echo "  --remove-volume       Delete volume after success"
    echo "  --cheap               Use cheap servers (cx23) for integrated test"
    echo "  --reuse-seed <IP>     Reuse existing Manager server"
    echo "  --reuse-beast <IP>    Rescue Mode: Resume build on existing server"
    exit 1
}

[ -z "$1" ] && [ "$1" != "--cleanup" ] && usage
VERSION="$1"; [ "$VERSION" != "--cleanup" ] && shift || VERSION=""
TARGET=""; KEEP_VOLUME=true; CHEAP_MODE=false; REUSE_BEAST_IP=""; REUSE_SEED_IP=""
DO_CLEANUP=false

while [ $# -gt 0 ]; do
    case "$1" in
        --cleanup) DO_CLEANUP=true; shift ;;
        --target) TARGET="$2"; shift 2 ;;
        --remove-volume) KEEP_VOLUME=false; shift ;;
        --cheap) CHEAP_MODE=true; shift ;;
        --reuse-seed) REUSE_SEED_IP="$2"; shift 2 ;;
        --reuse-beast) REUSE_BEAST_IP="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "$HCLOUD_TOKEN" ]; then echo "❌ ERROR: HCLOUD_TOKEN not set."; exit 1; fi

# ── 0.3 Toolchain Look-Ahead (Safety First) ──────────────────────────────────
# WHY: We peek at the Chromium source code on GitHub BEFORE starting the build.
# This prevents wasting money on a server only to find out at the very end 
# that your Windows toolchain archive is the wrong version.
if [ "$TARGET" = "win" ] || [ "$TARGET" = "all" ]; then
    echo "🔍 Checking Windows SDK requirements for Chromium $VERSION..."
    VS_TOOLCHAIN_URL="https://raw.githubusercontent.com/chromium/chromium/$VERSION/build/vs_toolchain.py"
    VS_PY=$(curl -sL "$VS_TOOLCHAIN_URL")
    
    if [ -z "$VS_PY" ]; then
        echo "❌ ERROR: Could not fetch vs_toolchain.py for version $VERSION."
        echo "   Check if the version tag is correct: https://github.com/chromium/chromium/tags"
        exit 1
    fi

    REQ_SDK=$(echo "$VS_PY" | grep "SDK_VERSION =" | head -n 1 | cut -d"'" -f2)
    REQ_HASH=$(echo "$VS_PY" | grep "TOOLCHAIN_HASH =" | head -n 1 | cut -d"'" -f2)
    
    echo "  -> Required SDK  : $REQ_SDK"
    echo "  -> Required Hash : $REQ_HASH"

    # Check our repository for the release
    # REPO: github.com/naminx/chromium-mv2
    CHECK_URL="https://github.com/naminx/chromium-mv2/releases/download/$REQ_SDK/$REQ_HASH.7z"
    echo "  -> Checking Repo : $CHECK_URL"
    
    if ! curl -sL --head "$CHECK_URL" | grep -q "200 OK"; then
        echo ""
        echo "❌ FATAL: Required Windows Toolchain NOT found in your repository!"
        echo "════════════════════════════════════════════════════════════════════"
        echo " Action Required:"
        echo " 1. Boot your Windows VM."
        echo " 2. Install Windows SDK: $REQ_SDK"
        echo " 3. Run: ./package-toolchain.sh --version $REQ_SDK --hash $REQ_HASH"
        echo " 4. This will upload the new $REQ_HASH.7z to GitHub."
        echo "════════════════════════════════════════════════════════════════════"
        exit 1
    fi
    echo "  ✅ Toolchain verified in repository."
fi

# ── 1. Validation & Cleanup ──────────────────────────────────────────────────
if [ "$DO_CLEANUP" = "true" ]; then
    if [ -n "$REUSE_BEAST_IP" ] || [ -n "$REUSE_SEED_IP" ]; then
        echo "❌ ERROR: --cleanup cannot be used with --reuse-seed or --reuse-beast."
        exit 1
    fi
    echo "☢️  NUCLEAR CLEANUP: Purging all project resources..."
    SERVERS=$(hcloud server list --selector "build" -o noheader -o columns=name)
    for s in $SERVERS; do hcloud server delete "$s"; done
    if hcloud volume describe "$VOLUME_NAME" &>/dev/null; then
        hcloud volume detach "$VOLUME_NAME" 2>/dev/null || true
        until [ "$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r .server)" = "null" ]; do sleep 2; done
        hcloud volume delete "$VOLUME_NAME"
    fi
    echo "✅ Project reset."; exit 0
fi

if [ -z "$TARGET" ]; then usage; fi

# ── 2. Safety Check ──────────────────────────────────────────────────────────
if [ "$KEEP_VOLUME" = "false" ]; then
    if [ -z "$GITHUB_TOKEN" ]; then echo "❌ ERROR: GITHUB_TOKEN required for --remove-volume."; exit 1; fi
    if ! curl -s -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user | grep -q "login"; then
        echo "❌ ERROR: GITHUB_TOKEN is invalid."; exit 1
    fi
fi

# ── 3. Setup ─────────────────────────────────────────────────────────────────
LOCAL_TZ=$(cat /etc/timezone 2>/dev/null || timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
SSH_KEY_ID=$(hcloud ssh-key list -o json | jq -r '.[0].id // ""')

if ! hcloud volume describe "$VOLUME_NAME" &>/dev/null; then
    hcloud volume create --name "$VOLUME_NAME" --size "$VOLUME_SIZE" --location "$PRIMARY_LOC" --format ext4
fi

# ── 3.1 Aggressive Purge ─────────────────────────────────────────────────────
echo "🧹 Purging orphaned build servers..."
OLD_SERVERS=$(hcloud server list --selector "build" -o json | jq -r '.[].public_net.ipv4.ip')
for IP in $OLD_SERVERS; do
    if [ "$IP" != "$REUSE_BEAST_IP" ] && [ "$IP" != "$REUSE_SEED_IP" ]; then
        NAME=$(hcloud server list -o json | jq -r ".[] | select(.public_net.ipv4.ip == \"$IP\") | .name")
        echo "  🗑️  Killing lingering server: $NAME ($IP)..."
        hcloud server delete "$NAME" > /dev/null 2>&1 || true
    fi
done

# ── 4. The Monolith Generator ───────────────────────────────────────────────
generate_monolith_script() {
    local IS_MANAGER="$1"; local CURRENT_VOL_ID=$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r .id)
    cat << BASH
#!/usr/bin/env bash
set -e
export HOME=/root
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export TZ="${LOCAL_TZ}"; export VERSION="${VERSION}"; export TARGET="${TARGET}"
export HCLOUD_TOKEN="${HCLOUD_TOKEN}"; export GITHUB_TOKEN="${GITHUB_TOKEN}"
export VOL_ID="${CURRENT_VOL_ID}"; export VOLUME_NAME="${VOLUME_NAME}"

# 4.1 PROVEN LOGGER STARTUP
exec > /var/log/build.log 2>&1
echo "📦 Initializing System..."
apt-get update && apt-get install -y curl jq git python3 psmisc moreutils software-properties-common libfuse2

# Install CLI tools (Required for handoff and release)
if ! command -v hcloud &>/dev/null; then
    curl -fsSL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar -xz -C /usr/local/bin hcloud
fi
if ! command -v gh &>/dev/null; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    apt-get update && apt-get install -y gh
fi
exec > >(ts '[%Y-%m-%d %H:%M:%S]' > /var/log/build.log) 2>&1
echo "--- Build Script Started (\$(hostname)) ---"

# 4.2 PROVEN HOST PREPARATION
if ! command -v docker &>/dev/null; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu jammy stable" > /etc/apt/sources.list.d/docker.list
    apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io
fi
systemctl start docker

# 4.3 PROVEN VOLUME DISCOVERY
# WHY: Size-based discovery is the only reliable way to find the disk in a cloud loop.
VOL_DEV=""
for i in {1..12}; do
    VOL_DEV="/dev/\$(lsblk -dno NAME,SIZE | grep '150G' | awk '{print \$1}' | head -n 1)"
    [ -n "\$VOL_DEV" ] && [ "\$VOL_DEV" != "/dev/" ] && break
    sleep 5
done
[ -z "\$VOL_DEV" ] || [ "\$VOL_DEV" = "/dev/" ] && VOL_DEV="/dev/disk/by-id/scsi-0HC_Volume_\$VOL_ID"

mkdir -p /mnt/chromium
# WHY: Already Mounted check avoids infinite retry loops.
if ! mountpoint -q /mnt/chromium; then
    grep "\$VOL_DEV" /proc/mounts | awk '{print \$2}' | xargs umount -l 2>/dev/null || true
    until mount "\$VOL_DEV" /mnt/chromium || [ \$? -eq 32 ]; do 
        mountpoint -q /mnt/chromium && break
        sleep 5
    done
fi

# 4.4 PROVEN SWAP ACTIVATION
if [ ! -f "/mnt/chromium/.swapfile" ]; then
    echo "💾 Creating 20GB Swap file..."
    fallocate -l 20G /mnt/chromium/.swapfile || dd if=/dev/zero of=/mnt/chromium/.swapfile bs=1M count=20480
    chmod 600 /mnt/chromium/.swapfile && mkswap /mnt/chromium/.swapfile
fi
grep -q "/mnt/chromium/.swapfile" /proc/swaps || swapon /mnt/chromium/.swapfile 2>/dev/null || true

# 4.5 PROVEN WORKSPACE UPDATE
cd /mnt/chromium
if [ -f "/tmp/build-docker.sh" ]; then
    mv /tmp/build-docker.sh build-docker.sh; chmod +x build-docker.sh
    [ -d "/tmp/patches" ] && (cp -r /tmp/patches/* patches/ 2>/dev/null || true)
fi

# 4.6 DELEGATION (Single Source of Truth)
if [ "$IS_MANAGER" = "true" ]; then
    export VOLUME_NAME="/mnt/chromium"
    ./build-docker.sh "\$VERSION" --target all --setup-only
    
    # Handoff
    BEAST_NAME="beast-\$(date +%s)"
    cd / && sync && swapoff /mnt/chromium/.swapfile 2>/dev/null || true
    hcloud volume detach "$VOLUME_NAME"
    until [ "\$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r .server)" = "null" ]; do sleep 2; done
    
    TYPE="ccx63"; [ "$CHEAP_MODE" = "true" ] && TYPE="cx23"
    hcloud server create --name "\$BEAST_NAME" --type "\$TYPE" --image "$IMAGE" --volume "$VOLUME_NAME" --ssh-key "${SSH_KEY_ID}" --label "build=chromium-beast" --user-data-from-file "/tmp/monolith_beast.sh" --location "$PRIMARY_LOC"
    hcloud server delete \$(hostname)
else
    # Beast Build Logic
    TOTAL_RAM_GB=\$(awk '/MemTotal/{printf "%d", \$2/1024/1024}' /proc/meminfo)
    if [ "\$TOTAL_RAM_GB" -ge 64 ]; then
        mkdir -p /mnt/chromium/src/out; mount -t tmpfs -o size=40G tmpfs /mnt/chromium/src/out
        mkdir -p /mnt/chromium/out_ramdisk; mount --bind /mnt/chromium/src/out /mnt/chromium/out_ramdisk
    fi
    
    export VOLUME_NAME="/mnt/chromium"; export SKIP_GCLIENT_SYNC=1
    ./build-docker.sh "\$VERSION" --target "\$TARGET"
    
    if [ -n "\$GITHUB_TOKEN" ]; then
        FILES=\$(ls *.deb *.exe 2>/dev/null || true)
        [ -n "\$FILES" ] && (gh release upload "v\$VERSION" \$FILES --clobber || gh release create "v\$VERSION" \$FILES)
    fi
    # Final Cleanup
    if [ "$KEEP_VOLUME" = "false" ]; then
        cd / && umount /mnt/chromium/out_ramdisk || true && umount /mnt/chromium/src/out || true && umount /mnt/chromium
        hcloud volume detach "$VOLUME_NAME"; until [ "$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r .server)" = "null" ]; do sleep 2; done
        hcloud volume delete "$VOLUME_NAME"
    fi
    hcloud server delete \$(hostname)
fi
BASH
}

# ── 5. Deployment ────────────────────────────────────────────────────────────
generate_monolith_script "true" > /tmp/monolith_manager.sh
generate_monolith_script "false" > /tmp/monolith_beast.sh

if [ -n "$REUSE_BEAST_IP" ]; then
    echo "🆘 RESCUE MODE: Preparing $REUSE_BEAST_IP..."
    # SAFE CLEANUP: Use force/lazy unmount only. NEVER use fuser -km here.
    ssh -o StrictHostKeyChecking=no root@$REUSE_BEAST_IP "while mountpoint -q /mnt/chromium; do umount -f -l /mnt/chromium; done || true"

    BEAST_REUSE_JSON=$(hcloud server list --selector "build" -o json | jq -r ".[] | select(.public_net.ipv4.ip == \"$REUSE_BEAST_IP\")")
    BEAST_ID_REUSE=$(echo "$BEAST_REUSE_JSON" | jq -r .id)
    BEAST_NAME_REUSE=$(echo "$BEAST_REUSE_JSON" | jq -r .name)
    [ -z "$BEAST_NAME_REUSE" ] && (echo "❌ Server not found."; exit 1)

    echo "🔗 Verifying volume attachment..."
    CUR_VOL=$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r '.server // "null"')
    if [ "$CUR_VOL" != "$BEAST_ID_REUSE" ]; then
        echo "  -> Attaching volume to $BEAST_NAME_REUSE..."
        hcloud volume detach "$VOLUME_NAME" 2>/dev/null || true
        until [ "$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r .server)" = "null" ]; do sleep 2; done
        hcloud volume attach "$VOLUME_NAME" --server "$BEAST_NAME_REUSE"
        until [ "$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r .server)" = "$BEAST_ID_REUSE" ]; do sleep 2; done
        ssh -o StrictHostKeyChecking=no root@$REUSE_BEAST_IP "umount -l /mnt/chromium || true"
    fi

    generate_monolith_script "false" > /tmp/monolith_beast.sh
    scp -o StrictHostKeyChecking=no -qr /tmp/monolith_beast.sh build-docker.sh patches root@$REUSE_BEAST_IP:/tmp/
    
    # THE PROCESS MASSACRE (WHY): Terminate lingering build-related tasks.
    ssh -o StrictHostKeyChecking=no root@$REUSE_BEAST_IP "fuser -k /var/log/build.log || true; pkill -9 -f monolith || true; pkill -9 -f build-docker || true; pkill -9 -f gclient || true; pkill -9 -f vpython || true; pkill -9 -f git || true; pkill -9 -u root bash || true; rm -f /var/log/build.log" || true
    
    ssh -o StrictHostKeyChecking=no root@$REUSE_BEAST_IP "bash /tmp/monolith_beast.sh" > /dev/null 2>&1 &
    exit 0
fi

if [ -n "$REUSE_SEED_IP" ]; then
    echo "🌱 REUSING SEED: Preparing $REUSE_SEED_IP..."
    # SAFE CLEANUP: Use force/lazy unmount only. NEVER use fuser -km here.
    ssh -o StrictHostKeyChecking=no root@$REUSE_SEED_IP "while mountpoint -q /mnt/chromium; do umount -f -l /mnt/chromium; done || true"

    SEED_REUSE_JSON=$(hcloud server list --selector "build" -o json | jq -r ".[] | select(.public_net.ipv4.ip == \"$REUSE_SEED_IP\")")
    SEED_ID_REUSE=$(echo "$SEED_REUSE_JSON" | jq -r .id)
    SEED_NAME_REUSE=$(echo "$SEED_REUSE_JSON" | jq -r .name)
    [ -z "$SEED_NAME_REUSE" ] && (echo "❌ Server not found."; exit 1)

    echo "🔗 Verifying volume attachment..."
    CUR_VOL=$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r '.server // "null"')
    if [ "$CUR_VOL" != "$SEED_ID_REUSE" ]; then
        echo "  -> Attaching volume to $SEED_NAME_REUSE..."
        hcloud volume detach "$VOLUME_NAME" 2>/dev/null || true
        until [ "$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r .server)" = "null" ]; do sleep 2; done
        hcloud volume attach "$VOLUME_NAME" --server "$SEED_NAME_REUSE"
        until [ "$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r .server)" = "$SEED_ID_REUSE" ]; do sleep 2; done
        ssh -o StrictHostKeyChecking=no root@$REUSE_SEED_IP "umount -l /mnt/chromium || true"
    fi

    generate_monolith_script "true" > /tmp/monolith_manager.sh
    scp -o StrictHostKeyChecking=no -qr /tmp/monolith_manager.sh /tmp/monolith_beast.sh build-docker.sh patches root@$REUSE_SEED_IP:/tmp/
    
    # THE PROCESS MASSACRE (WHY): Terminate lingering build-related tasks.
    ssh -o StrictHostKeyChecking=no root@$REUSE_SEED_IP "fuser -k /var/log/build.log || true; pkill -9 -f monolith || true; pkill -9 -f build-docker || true; pkill -9 -f gclient || true; pkill -9 -f vpython || true; pkill -9 -f git || true; pkill -9 -u root bash || true; rm -f /var/log/build.log" || true
    
    ssh -o StrictHostKeyChecking=no root@$REUSE_SEED_IP "bash /tmp/monolith_manager.sh" > /dev/null 2>&1 &
    exit 0
fi

SEED_NAME="manager-seed-$(date +%s)"
hcloud server create --name "$SEED_NAME" --type "cx23" --image "$IMAGE" --volume "$VOLUME_NAME" --ssh-key "${SSH_KEY_ID}" --label "build=chromium-manager" > /dev/null
SEED_IP=$(hcloud server describe "$SEED_NAME" -o json | jq -r .public_net.ipv4.ip)
until ssh -o StrictHostKeyChecking=no root@$SEED_IP uptime &>/dev/null; do sleep 5; done
scp -o StrictHostKeyChecking=no -qr /tmp/monolith_manager.sh /tmp/monolith_beast.sh build-docker.sh patches root@$SEED_IP:/tmp/
ssh -o StrictHostKeyChecking=no root@$SEED_IP "bash /tmp/monolith_manager.sh" > /dev/null 2>&1 &
echo "🎉 Started. Manager: $SEED_IP"
