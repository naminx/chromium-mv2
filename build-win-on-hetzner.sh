#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
GDRIVE_PATH="chromium-mv2-cache"
RCLONE_CONF="${HOME}/.config/rclone/rclone.conf"

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./build-win-on-hetzner.sh <HETZNER_IP> <CHROMIUM_VERSION> [OPTIONS]"
    echo ""
    echo "  --from-cache <PREV>   Restore cached out/win/ from Google Drive before building."
    echo "                        Enables incremental compilation on Hetzner."
    echo "  --api <TOKEN>         Hetzner API token. If provided, the server will"
    echo "                        SELF-DESTRUCT after a successful build + upload."
    echo ""
    echo "Google Drive remote (default: 'gdrive'): GDRIVE_REMOTE=myname ./build-win-on-hetzner.sh ..."
    echo "Artifacts stored in Google Drive folder : $GDRIVE_PATH/"
    echo ""
    echo "Prerequisites: run 'rclone config' locally and name the remote '$GDRIVE_REMOTE'."
    exit 1
fi

HETZNER_IP="$1"
CHROMIUM_VERSION="$2"
USE_CACHE=0
PREV_VERSION=""

HETZNER_API=""

# Parse remaining flags (--from-cache <PREV> and/or --api <TOKEN>, any order)
SHIFT_ARGS=("$@")
for (( i=2; i<${#SHIFT_ARGS[@]}; i++ )); do
    if [ "${SHIFT_ARGS[$i]}" = "--from-cache" ] && [ -n "${SHIFT_ARGS[$((i+1))]}" ]; then
        USE_CACHE=1
        PREV_VERSION="${SHIFT_ARGS[$((i+1))]}"
        i=$((i+1))
    elif [ "${SHIFT_ARGS[$i]}" = "--api" ] && [ -n "${SHIFT_ARGS[$((i+1))]}" ]; then
        HETZNER_API="${SHIFT_ARGS[$((i+1))]}"
        i=$((i+1))
    fi
done

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# ── Validate prerequisites ────────────────────────────────────────────────────
if [ ! -f "$RCLONE_CONF" ]; then
    echo "❌ rclone config not found at $RCLONE_CONF"
    echo "   Run 'rclone config' to set up a Google Drive remote named '$GDRIVE_REMOTE'."
    exit 1
fi

echo "====================================================================="
echo "Windows Chromium Build on Hetzner"
echo "  Version : $CHROMIUM_VERSION"
if [ "$USE_CACHE" = "1" ]; then
    echo "  Cache   : $GDRIVE_REMOTE:$GDRIVE_PATH/out-win-${PREV_VERSION}.tar.gz  (download before build)"
fi
echo "  Upload  : $GDRIVE_REMOTE:$GDRIVE_PATH/out-win-${CHROMIUM_VERSION}.tar.gz  (upload after build)"
if [ -n "$HETZNER_API" ]; then
    echo "  💥 API TOKEN SET: server will SELF-DESTRUCT after successful build + upload."
else
    echo "  🛑 No API token: you must delete the server manually when done."
fi
echo "Make sure your patches/ are saved locally! Press Enter to proceed (Ctrl+C to abort)."
read -rp "..."

# ── Generate the autonomous build script locally ──────────────────────────────
# We write it to a local temp file (two heredocs: first injects variables via
# local expansion, second appends the script body with no local expansion).
TMPSCRIPT="$(mktemp /tmp/autonomous_build.XXXXXX.sh)"

# Part 1: hardcode all config values (local bash expands the variables)
cat > "$TMPSCRIPT" << EOF
#!/usr/bin/env bash
CHROMIUM_VERSION="$CHROMIUM_VERSION"
USE_CACHE="$USE_CACHE"
PREV_VERSION="$PREV_VERSION"
GDRIVE_REMOTE="$GDRIVE_REMOTE"
GDRIVE_PATH="$GDRIVE_PATH"
HETZNER_API="$HETZNER_API"
TOOLCHAIN_HASH="42b5b0689e"
export TOOLCHAIN_PASS="$TOOLCHAIN_PASS"
EOF

# Part 2: script body — single-quoted so NO local expansion; all $VAR are remote
cat >> "$TMPSCRIPT" << 'SCRIPTEND'
CACHE_TARBALL="out-win-${PREV_VERSION}.tar.gz"
BUILD_TARBALL="out-win-${CHROMIUM_VERSION}.tar.gz"

echo "======================================"
echo "Windows Chromium Build at $(date)"
echo "======================================"

cd /root/chromium-mv2

# ── Step 1: Restore cached artifacts (if requested) ──────────────────────────
if [ "$USE_CACHE" = "1" ] && [ -n "$PREV_VERSION" ]; then
    echo ""
    echo "📦 Looking for cached artifacts: ${GDRIVE_REMOTE}:${GDRIVE_PATH}/${CACHE_TARBALL}"
    if rclone lsf "${GDRIVE_REMOTE}:${GDRIVE_PATH}/${CACHE_TARBALL}" > /dev/null 2>&1; then
        echo "📥 Cache found! Downloading..."
        rclone copy "${GDRIVE_REMOTE}:${GDRIVE_PATH}/${CACHE_TARBALL}" /tmp/ --progress
        echo "📂 Extracting into Docker volume..."
        docker volume create chromium-mv2-src > /dev/null 2>&1 || true
        docker run --rm \
            -v chromium-mv2-src:/chromium \
            -v /tmp/${CACHE_TARBALL}:/cache.tar.gz:ro \
            ubuntu:22.04 \
            bash -c "mkdir -p /chromium/src && tar xzf /cache.tar.gz -C /chromium/src/ && echo 'Extraction complete.'"
        rm -f "/tmp/${CACHE_TARBALL}"
        echo "✅ Cache restored at $(date). Build will be incremental."
    else
        echo "⚠️  Cache not found on Google Drive. Building from scratch."
    fi
fi

# ── Step 2: Build ─────────────────────────────────────────────────────────────
echo ""
BUILD_CMD="./build-docker.sh $CHROMIUM_VERSION"
if [ "$USE_CACHE" = "1" ] && [ -n "$PREV_VERSION" ]; then
    BUILD_CMD="./build-docker.sh $CHROMIUM_VERSION --from-cache $PREV_VERSION"
fi
echo "🏗️  Starting $BUILD_CMD ..."
if $BUILD_CMD; then
    echo ""
    echo "🎉 BUILD SUCCESS at $(date)"

    # ── Step 3a: Upload mini_installer.exe first (114 MB — fast, highest priority)
    EXE_NAME="mini_installer-${CHROMIUM_VERSION}.exe"
    echo ""
    echo "☁️  Uploading ${EXE_NAME} to ${GDRIVE_REMOTE}:${GDRIVE_PATH}/releases/ ..."
    rclone copy "/root/chromium-mv2/${EXE_NAME}" "${GDRIVE_REMOTE}:${GDRIVE_PATH}/releases/" --progress
    echo "✅ Installer uploaded at $(date)."
    echo "   Download: rclone copy ${GDRIVE_REMOTE}:${GDRIVE_PATH}/releases/${EXE_NAME} ./"

    # ── Step 3b: Archive out/win/ and upload tarball (for next incremental build)
    echo ""
    echo "📦 Archiving build artifacts (out/win/)..."
    docker run --rm \
        -v chromium-mv2-src:/chromium \
        -v /tmp:/output \
        ubuntu:22.04 \
        bash -c "cd /chromium/src && tar czf /output/${BUILD_TARBALL} out/win/ && echo 'Archive size: '$(du -sh /output/${BUILD_TARBALL} | cut -f1)"

    echo "☁️  Uploading ${BUILD_TARBALL} to ${GDRIVE_REMOTE}:${GDRIVE_PATH}/ ..."
    rclone copy "/tmp/${BUILD_TARBALL}" "${GDRIVE_REMOTE}:${GDRIVE_PATH}/" --progress
    rm -f "/tmp/${BUILD_TARBALL}"
    echo "✅ Artifacts tarball uploaded at $(date)."
    echo "   Next build: ./build-win-on-hetzner.sh <IP> <NEW_VER> --from-cache ${CHROMIUM_VERSION}"

    # ── Self-destruct (only after successful build AND upload) ────────────────
    if [ -n "$HETZNER_API" ]; then
        echo ""
        echo "💥 Self-destructing server..."
        SERVER_ID=$(curl -s http://169.254.169.254/hetzner/v1/metadata/instance-id)
        curl -sf -X DELETE -H "Authorization: Bearer $HETZNER_API" \
            "https://api.hetzner.cloud/v1/servers/${SERVER_ID}" && \
            echo "✅ Server deletion request sent." || \
            echo "⚠️  Self-destruct request failed — delete manually from Hetzner dashboard."
    fi
else
    echo ""
    echo "❌ BUILD FAILED at $(date). See log above."
fi
SCRIPTEND

chmod +x "$TMPSCRIPT"

# ── Sync files and script to Hetzner ─────────────────────────────────────────
echo ""
echo "🚀 Preparing Hetzner ($HETZNER_IP)..."
ssh $SSH_OPTS root@$HETZNER_IP "mkdir -p /root/chromium-mv2"

echo "📤 Synchronizing build scripts and patches..."
rsync -a -e "ssh $SSH_OPTS" --info=progress2 \
    --exclude='.git*' \
    --exclude='out' \
    --exclude='*.exe' \
    "$SCRIPT_DIR/" root@$HETZNER_IP:/root/chromium-mv2/

echo "📤 Uploading autonomous build script..."
scp $SSH_OPTS "$TMPSCRIPT" root@$HETZNER_IP:/root/autonomous_build.sh
rm -f "$TMPSCRIPT"

echo "📤 Copying rclone config..."
ssh $SSH_OPTS root@$HETZNER_IP "mkdir -p /root/.config/rclone"
scp $SSH_OPTS "$RCLONE_CONF" root@$HETZNER_IP:/root/.config/rclone/rclone.conf

# ── Remote setup and launch ───────────────────────────────────────────────────
echo "⚙️  Configuring Hetzner environment and launching build..."
ssh $SSH_OPTS root@$HETZNER_IP << EOF
set -e

echo "📦 Installing Docker + rclone (if missing)..."
if ! command -v docker &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq docker.io
fi
if ! command -v rclone &>/dev/null; then
    curl -fsSL https://rclone.org/install.sh | bash > /dev/null
fi
echo "✅ Docker + rclone ready."

chmod +x /root/autonomous_build.sh
echo "🚀 Launching autonomous build in background (nohup)..."
nohup /root/autonomous_build.sh > /var/log/build.log 2>&1 &

echo "====================================================================="
echo "✅ Build launched! You can safely close your terminal."
echo ""
echo "Monitor : ./tail-hetzner.sh $HETZNER_IP"
echo ""
echo "When done, download the installer:"
echo "  scp $SSH_OPTS root@$HETZNER_IP:/root/chromium-mv2/mini_installer-$CHROMIUM_VERSION.exe ./"
echo ""
if [ -n "$HETZNER_API" ]; then
    echo "💥 API TOKEN DETECTED: server will AUTOMATICALLY DELETE ITSELF after build + upload!"
else
    echo "🛑 NO API TOKEN: you MUST delete the server manually from the Hetzner dashboard."
fi
echo "====================================================================="
EOF
