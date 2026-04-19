#!/usr/bin/env bash
# build-hetzner.sh — Self-Healing Monolithic Orchestrator
set -e

# --- Configuration ---
VOLUME_NAME="chromium-mv2-src-vol"
VOLUME_SIZE=150
PRIMARY_LOC="hel1"
RAM_DISK_SIZE="40G"
IMAGE="ubuntu-22.04"

usage() {
    echo "Usage: $0 <VERSION> --target <deb|win> --api-key <TOKEN> [options]"
    echo ""
    echo "Options:"
    echo "  --gh-token <TOKEN>    Upload results to GitHub release"
    echo "  --remove-volume       Delete volume after success"
    echo "  --dry-run             Use cheap servers and skip Chromium build"
    echo "  --cheap               Use cheap servers (cx23) but run real Chromium build"
    echo "  --skip-sync           Skip Seed server, launch Beast immediately"
    echo "  --sync                Force source sync on the Beast"
    echo "  --reuse-beast <IP>    Don't create any servers, run build on existing IP"
    exit 1
}

[ -z "$1" ] && usage
VERSION="$1"; shift
TARGET=""; API_KEY=""; GH_TOKEN=""; KEEP_VOLUME=true; DRY_RUN=false
CHEAP_MODE=false; SKIP_SYNC=false; FORCE_SYNC=false; REUSE_BEAST_IP=""

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --api-key) API_KEY="$2"; shift 2 ;;
        --gh-token) GH_TOKEN="$2"; shift 2 ;;
        --remove-volume) KEEP_VOLUME=false; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --cheap) CHEAP_MODE=true; shift ;;
        --skip-sync) SKIP_SYNC=true; shift ;;
        --sync) FORCE_SYNC=true; shift ;;
        --reuse-beast) REUSE_BEAST_IP="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "$TARGET" ] || [ -z "$API_KEY" ]; then usage; fi
export HCLOUD_TOKEN="$API_KEY"

# ── Phase 0: Safety Validation ───────────────────────────────────────────────
# ARCHITECTURE NOTE: This system uses two servers:
# 1. Manager (Seed): Cheap CX23 ($0.008/hr) that performs the 100GB source sync.
# 2. Beast (Worker): Powerful CCX63 (48-core) that performs the heavy Ninja compilation.
# The persistent "Universal Volume" is handed off from Manager to Beast.

if [ "$KEEP_VOLUME" = "false" ]; then
    # CRITICAL SAFETY: If the user wants to delete the volume after build,
    # we MUST ensure they have a working GitHub token first, or their
    # installers (.deb/.exe) will be lost forever when the volume dies.
    if [ -z "$GH_TOKEN" ]; then
        echo "❌ ERROR: --remove-volume requires --gh-token to save your installers!"
        exit 1
    fi
    echo "🔐 Verifying GitHub token..."
    if ! curl -s -H "Authorization: token $GH_TOKEN" https://api.github.com/user | grep -q "login"; then
        echo "❌ ERROR: The provided --gh-token is invalid or expired."
        exit 1
    fi
    echo "  ✅ GitHub token verified."
fi

# ── Phase 0.1: Setup ─────────────────────────────────────────────────────────
LOCAL_TZ=$(cat /etc/timezone 2>/dev/null || timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
SSH_KEY_ID=$(hcloud ssh-key list -o json | jq -r '.[0].id // ""')
if [ "$SSH_KEY_ID" = "" ] || [ "$SSH_KEY_ID" = "null" ]; then
    echo "❌ No SSH key found in Hetzner account."
    exit 1
fi

# ── Phase 0.1: Aggressive Purge ──────────────────────────────────────────────
echo "🧹 Searching for lingering build servers..."
OLD_SERVERS=$(hcloud server list --selector "build" -o json | jq -r '.[].public_net.ipv4.ip')
for IP in $OLD_SERVERS; do
    if [ "$IP" != "$REUSE_BEAST_IP" ]; then
        NAME=$(hcloud server list -o json | jq -r ".[] | select(.public_net.ipv4.ip == \"$IP\") | .name")
        echo "  🗑️  Killing lingering server: $NAME ($IP)..."
        hcloud server delete "$NAME" > /dev/null 2>&1 || true
    fi
done

if ! hcloud volume describe "$VOLUME_NAME" &>/dev/null; then
    echo "  🔨 Creating 150GB Volume..."
    hcloud volume create --name "$VOLUME_NAME" --size "$VOLUME_SIZE" --location "$PRIMARY_LOC" --format ext4
fi

# ── Helper: The Monolith Script Generator ────────────────────────────────────
# THE MONOLITH STRATEGY:
# Instead of scp-ing many small scripts, we bake EVERYTHING into one giant
# shell script. This prevents "File Not Found" errors when the Beast server
# boots, as it has the entire instruction set in its User-Data from the start.
generate_monolith_script() {
    local SEED_TO_KILL="$1"; local BEAST_TO_KILL="$2"; local FORCE_SYNC_VAL="$3"; local IS_MANAGER="$4"
    local CURRENT_VOL_ID=$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r .id)

    cat << 'EOF_BASH'
#!/usr/bin/env bash
set -e

# --- 1. Environment ---
# cloud-init often runs with a minimal environment. We explicitly set
# HOME and PATH to ensure tools like 'git' and 'gh' work correctly.
export HOME=/root
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LOCAL_TZ="${LOCAL_TZ}"
export VERSION="${VERSION}"
export TARGET="${TARGET}"
export API_KEY="${API_KEY}"
export GH_TOKEN="${GH_TOKEN}"
export VOL_ID="${CURRENT_VOL_ID}"
export VOLUME_NAME="${VOLUME_NAME}"
export KEEP_VOLUME="${KEEP_VOLUME}"
export DRY_RUN="${DRY_RUN}"
export CHEAP_MODE="${CHEAP_MODE}"
export RAM_DISK_SIZE="${RAM_DISK_SIZE}"
export SHOULD_SYNC="${FORCE_SYNC_VAL}"
export IS_MANAGER="${IS_MANAGER}"
export SEED_NAME_TO_DELETE="${SEED_TO_KILL}"
export BEAST_NAME_TO_DELETE="${BEAST_TO_KILL}"
export TZ="\$LOCAL_TZ"

# --- 2. Logger ---
exec > /var/log/build.log 2>&1
echo "📦 Initializing Logger..."
apt-get update -qq && apt-get install -y moreutils psmisc curl jq git python3 > /dev/null
exec > >(ts '[%Y-%m-%d %H:%M:%S]' > /var/log/build.log) 2>&1
echo "--- Build Script Started (\$(hostname)) ---"

# --- 3. Nuclear Host Preparation ---
echo "🔧 Preparing Host Environment..."
# 3.1 Unblock Package Manager
# Forcefully remove lock files in case a previous build crashed mid-apt-update.
rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock* /var/cache/apt/archives/lock*
dpkg --configure -a || true
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y curl jq git python3 psmisc moreutils ca-certificates gnupg software-properties-common lsb-release libfuse2
# 3.2 Docker Resilience (The PID fix)
if ! command -v docker &>/dev/null; then
    echo "🐳 Installing Docker Engine..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu jammy stable" > /etc/apt/sources.list.d/docker.list
    apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io
fi
echo "🐳 Resetting Docker service..."
systemctl stop docker.socket || true
systemctl stop docker || true
# Kill corrupted PID files that cause Docker to crash with "I/O error"
rm -f /var/run/docker.pid /var/run/docker.sock
# Kill any ghost mounts from previous crashes (prevents overlayfs deadlock)
grep overlay /proc/mounts | cut -d' ' -f2 | xargs umount -l 2>/dev/null || true
systemctl reset-failed docker || true
systemctl start docker || (journalctl -xeu docker.service | tail -n 20 && exit 1)

# 3.3 Robust Volume discovery
# In cloud environments, block devices (/dev/sdb, etc.) can take seconds to 
# initialize. We loop and wait, searching specifically for our 150GB disk.
echo "💾 Discovering and Mounting 150GB Volume..."
# Try finding by size first (more reliable than static device names)
VOL_DEV=""
for i in {1..12}; do
    VOL_DEV="/dev/\$(lsblk -dno NAME,SIZE | grep '150G' | awk '{print \$1}' | head -n 1)"
    [ -n "\$VOL_DEV" ] && [ "\$VOL_DEV" != "/dev/" ] && break
    echo "  -> Waiting for 150GB disk to appear (attempt \$i/12)..."
    sleep 5
done

# Fallback to ID if size discovery fails
[ -z "\$VOL_DEV" ] || [ "\$VOL_DEV" = "/dev/" ] && VOL_DEV="/dev/disk/by-id/scsi-0HC_Volume_\$VOL_ID"

mkdir -p /mnt/chromium
# Unmount ALL occurrences of this disk (prevents Hetzner automount conflict).
# Sometimes Hetzner's agent mounts it to /mnt/HC_Volume_XXX, which blocks us.
grep "\$VOL_DEV" /proc/mounts | awk '{print \$2}' | xargs umount -l 2>/dev/null || true
umount -l /mnt/chromium 2>/dev/null || true

until mount "\$VOL_DEV" /mnt/chromium; do
    echo "Waiting for volume \$VOL_DEV to be ready for mount..."
    sleep 5
done

# 3.4 Resilience
if [ ! -f "/mnt/chromium/.swapfile" ]; then
    fallocate -l 20G /mnt/chromium/.swapfile || dd if=/dev/zero of=/mnt/chromium/.swapfile bs=1M count=20480
    chmod 600 /mnt/chromium/.swapfile && mkswap /mnt/chromium/.swapfile
fi
grep -q "/mnt/chromium/.swapfile" /proc/swaps || swapon /mnt/chromium/.swapfile 2>/dev/null || true
git config --global pack.windowMemory "256m"
git config --global pack.threads "1"

# --- 4. Data Preparation ---
# UNIVERSAL STRATEGY: 
# To maximize speed, we always prepare the volume for BOTH Linux and Windows
# during the initial "Seed" phase. This allows the expensive Beast server
# to switch between targets (deb/win) without re-downloading toolchains.
if [ ! -f "/mnt/chromium/.deps_installed" ] || [ "\$IS_MANAGER" = "true" ] || [ "\$SHOULD_SYNC" = "true" ]; then
    echo "📥 Preparing Chromium Data and Toolchains (Universal Strategy)..."
    # We force 'all' during manager prep to ensure both toolchains are ready
    ORIG_TARGET="\$TARGET"
    [ "\$IS_MANAGER" = "true" ] && TARGET="all"

    cd /mnt/chromium
    [ ! -d "depot_tools" ] && git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
    export PATH="/mnt/chromium/depot_tools:\$PATH"
    git config --global safe.directory '*'

    echo "📝 Configuring .gclient..."
    # We overwrite the file with a perfectly formatted template (Universal)
    cat > .gclient << 'GCLIENTEOF'
solutions = [
    {
        "name": "src",
        "url": "https://chromium.googlesource.com/chromium/src.git",
        "managed": False,
        "custom_deps": {},
        "custom_vars": {},
    },
]
target_os = ["win", "linux"]
GCLIENTEOF

    if [ ! -d "src" ]; then git clone --depth 1 --branch "\$VERSION" --progress https://chromium.googlesource.com/chromium/src.git
    else git -C src fetch origin "refs/tags/\$VERSION" --depth 1 --progress && git -C src checkout FETCH_HEAD; fi
    gclient sync --nohooks --no-history --shallow --verbose -j\$(nproc)

    # Force Universal Sync: Download both Linux and Windows toolchains
    # DEPOT_TOOLS_WIN_TOOLCHAIN=1 ensures 'runhooks' fetches Windows SDKs.
    export DEPOT_TOOLS_WIN_TOOLCHAIN=1
    echo "🛠️  Running gclient hooks (Downloading universal toolchains)..."
    gclient runhooks
    echo "🔧 Updating universal Clang toolchain..."
    python3 tools/clang/scripts/update.py

    # Restore original target for metadata tracking
    TARGET="\$ORIG_TARGET"
    echo "all" > /mnt/chromium/.last_target
    touch /mnt/chromium/.deps_installed
    echo "✅ Universal Data Preparation Complete."
fi

# --- 5. Workspace Update ---
if [ -f "/tmp/build-docker.sh" ]; then
    mv /tmp/build-docker.sh /mnt/chromium/build-docker.sh; chmod +x /mnt/chromium/build-docker.sh
    [ -d "/tmp/patches" ] && (mkdir -p /mnt/chromium/patches && cp -r /tmp/patches/* /mnt/chromium/patches/ && rm -rf /tmp/patches)
fi

# --- 6. Execution Selection ---
if [ "\$IS_MANAGER" = "true" ]; then
    # SAFE HANDOFF PROCEDURE:
    # 1. Flush RAM to Volume (sync).
    # 2. Stop Swap to release file handles.
    # 3. Use Lazy Unmount (-l) to bypass kernel "Busy" locks.
    # 4. Spawns the Beast and passes THIS Monolith as user-data.
    BEAST_NAME="beast-\$(date +%s)"
    echo "🧹 Preparing volume for handoff..."
    cd / && sync && swapoff /mnt/chromium/.swapfile 2>/dev/null || true && sleep 5
    umount -l /mnt/chromium && export HCLOUD_TOKEN="\$API_KEY"
    hcloud volume detach "\$VOLUME_NAME"
    until [ "\$(hcloud volume describe "\$VOLUME_NAME" -o json | jq -r .server)" = "null" ]; do sleep 2; done

    TYPE="ccx63"; [ "\$CHEAP_MODE" = "true" ] && TYPE="cx23"
    # Flip the switch so the Beast knows its role
    sed -i 's/IS_MANAGER="true"/IS_MANAGER="false"/' /tmp/monolith.sh
    hcloud server create --name "\$BEAST_NAME" --type "\$TYPE" --image "${IMAGE}" --volume "\$VOLUME_NAME" --ssh-key "${SSH_KEY_ID}" --label "build=chromium-beast" --user-data-from-file "/tmp/monolith.sh" --location "${PRIMARY_LOC}"
    hcloud server delete \$(hostname)
else
    # BEAST BUILD LOGIC:
    # If the server has >= 64GB RAM, we use a 40GB RAM Disk for the 'out' directory.
    # This significantly reduces network I/O latency for object file creation.
    TOTAL_RAM_GB=\$(awk '/MemTotal/{printf "%d", \$2/1024/1024}' /proc/meminfo)
    if [ "\$TOTAL_RAM_GB" -ge 64 ]; then
        mkdir -p /mnt/chromium/src/out; mount -t tmpfs -o size=\$RAM_DISK_SIZE tmpfs /mnt/chromium/src/out
        mkdir -p /mnt/chromium/out_ramdisk; mount --bind /mnt/chromium/src/out /mnt/chromium/out_ramdisk
    fi
    cd /mnt/chromium; export VOLUME_NAME="/mnt/chromium"; export SKIP_GCLIENT_SYNC=1
    export VPYTHON_VENV_ROOT="/mnt/chromium/.cache/vpython"; export PIP_CACHE_DIR="/mnt/chromium/.cache/pip"
    ./build-docker.sh "\$VERSION" --target "\$TARGET"
    
    # Upload results before self-destructing
    if [ -n "\$GH_TOKEN" ]; then
        export GITHUB_TOKEN="\$GH_TOKEN"; FILES=\$(ls /mnt/chromium/*.deb /mnt/chromium/*.exe 2>/dev/null || true)
        [ -n "\$FILES" ] && (gh release upload "v\$VERSION" \$FILES --clobber || gh release create "v\$VERSION" \$FILES)
    fi
    
    # Final Cleanup
    export HCLOUD_TOKEN="\$API_KEY"
    if [ "\$KEEP_VOLUME" = "false" ]; then
        cd / && umount /mnt/chromium/out_ramdisk || true && umount /mnt/chromium/src/out || true && umount /mnt/chromium
        hcloud volume detach "\$VOLUME_NAME"; until [ "\$(hcloud volume describe "\$VOLUME_NAME" -o json | jq -r .server)" = "null" ]; do sleep 2; done
        hcloud volume delete "\$VOLUME_NAME"
    fi
    [ -n "\$SEED_NAME_TO_DELETE" ] && hcloud server delete "\$SEED_NAME_TO_DELETE" || true
    hcloud server delete \$(hostname)
fi
EOF_BASH
}

# ── Phase 1: Deployment ──────────────────────────────────────────────────────
if [ -n "$REUSE_BEAST_IP" ]; then
    echo "🆘 RESCUE MODE: Preparing $REUSE_BEAST_IP..."
    BEAST_REUSE_JSON=$(hcloud server list --selector "build" -o json | jq -r ".[] | select(.public_net.ipv4.ip == \"$REUSE_BEAST_IP\")")
    BEAST_NAME_REUSE=$(echo "$BEAST_REUSE_JSON" | jq -r .name)
    BEAST_ID_REUSE=$(echo "$BEAST_REUSE_JSON" | jq -r .id)
    [ -z "$BEAST_NAME_REUSE" ] && (echo "❌ Server not found." && exit 1)

    # ── FORCE ATTACHMENT ──
    echo "🔗 Verifying volume attachment..."
    CURRENT_ATTACHED_ID=$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r '.server // "null"')
    if [ "$CURRENT_ATTACHED_ID" != "$BEAST_ID_REUSE" ]; then
        echo "  -> Volume is detached or on wrong server. Re-attaching to $BEAST_NAME_REUSE..."
        hcloud volume detach "$VOLUME_NAME" 2>/dev/null || true
        until [ "$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r .server)" = "null" ]; do sleep 2; done
        hcloud volume attach "$VOLUME_NAME" --server "$BEAST_NAME_REUSE"
        until [ "$(hcloud volume describe "$VOLUME_NAME" -o json | jq -r .server)" = "$BEAST_ID_REUSE" ]; do sleep 2; done
        echo "  ✅ Volume attached."
    fi

    generate_monolith_script "" "$BEAST_NAME_REUSE" "$FORCE_SYNC" "false" > /tmp/monolith.sh
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -qr /tmp/monolith.sh build-docker.sh patches root@$REUSE_BEAST_IP:/tmp/
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$REUSE_BEAST_IP "fuser -k /var/log/build.log || true; pkill -9 -f build-docker || true; pkill -9 -f gclient || true; pkill -9 -f vpython || true; pkill -9 -f git || true; pkill -9 -u root bash || true; rm -f /var/log/build.log" || true
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$REUSE_BEAST_IP "bash /tmp/monolith.sh" > /dev/null 2>&1 &
    exit 0
fi

if [ "$SKIP_SYNC" = true ]; then
    BEAST_NAME="beast-direct-$(date +%s)"; TYPE="ccx63"; [ "$DRY_RUN" = "true" ] || [ "$CHEAP_MODE" = "true" ] && TYPE="cx23"
    generate_monolith_script "" "self" "$FORCE_SYNC" "false" > /tmp/monolith.sh
    BEAST_IP=$(hcloud server create --name "$BEAST_NAME" --type "$TYPE" --image "$IMAGE" --volume "$VOLUME_NAME" --ssh-key "$SSH_KEY_ID" --label "build=chromium-beast" --user-data-from-file "/tmp/monolith.sh" --location "$PRIMARY_LOC" -o json | jq -r .server.public_net.ipv4.ip)
    echo "✅ Beast launched at $BEAST_IP"; exit 0
fi

SEED_NAME="manager-seed-$(date +%s)"
generate_monolith_script "$SEED_NAME" "self" "false" "true" > /tmp/monolith.sh
hcloud server create --name "$SEED_NAME" --type "cx23" --image "$IMAGE" --location "$PRIMARY_LOC" --volume "$VOLUME_NAME" --ssh-key "$SSH_KEY_ID" --label "build=chromium-manager" > /dev/null
SEED_IP=$(hcloud server describe "$SEED_NAME" -o json | jq -r .public_net.ipv4.ip)

until ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$SEED_IP uptime &>/dev/null; do sleep 5; done
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -qr /tmp/monolith.sh build-docker.sh patches root@$SEED_IP:/tmp/
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$SEED_IP "bash /tmp/monolith.sh" > /dev/null 2>&1 &
echo "🎉 Autonomous build started. Manager: $SEED_IP"
