#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
GDRIVE_PATH="chromium-mv2-cache"
RCLONE_CONF="${HOME}/.config/rclone/rclone.conf"
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./build-binaries-on-hetzner.sh <HETZNER_IP> <CHROMIUM_VERSION> [OPTIONS]"
    echo ""
    echo "  --from-cache <PREV>   Restore cached out/win/ from Google Drive before building."
    echo "  --api <TOKEN>         Hetzner API token. If provided, the server will"
    echo "                        SELF-DESTRUCT after a successful build + upload."
    echo "  --target <TARGET>     Target platform: 'deb', 'win', or 'all' (default: all)."
    echo ""
    echo "Google Drive remote (default: 'gdrive'): GDRIVE_REMOTE=myname ./build-binaries-on-hetzner.sh ..."
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
BUILD_TARGET="all"
SHALLOW_CLONE="0"

# Parse remaining flags (--from-cache <PREV>, --api <TOKEN>, --target <TARGET>, --shallow any order)
SHIFT_ARGS=("$@")
for (( i=2; i<${#SHIFT_ARGS[@]}; i++ )); do
    if [ "${SHIFT_ARGS[$i]}" = "--from-cache" ] && [ -n "${SHIFT_ARGS[$((i+1))]}" ]; then
        USE_CACHE=1
        PREV_VERSION="${SHIFT_ARGS[$((i+1))]}"
        i=$((i+1))
    elif [ "${SHIFT_ARGS[$i]}" = "--api" ] && [ -n "${SHIFT_ARGS[$((i+1))]}" ]; then
        HETZNER_API="${SHIFT_ARGS[$((i+1))]}"
        i=$((i+1))
    elif [ "${SHIFT_ARGS[$i]}" = "--target" ] && [ -n "${SHIFT_ARGS[$((i+1))]}" ]; then
        BUILD_TARGET="${SHIFT_ARGS[$((i+1))]}"
        i=$((i+1))
    elif [ "${SHIFT_ARGS[$i]}" = "--shallow" ]; then
        SHALLOW_CLONE="1"
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
echo "Chromium Build on Hetzner (Linux + Windows)"
echo "  Version : $CHROMIUM_VERSION"
echo "  Target  : $BUILD_TARGET"
if [ "$USE_CACHE" = "1" ]; then
    echo "  Cache   : $GDRIVE_REMOTE:$GDRIVE_PATH/out-win-${PREV_VERSION}.tar.gz"
fi
[ "$BUILD_TARGET" = "all" ] || [ "$BUILD_TARGET" = "deb" ] && echo "  Debian  : $GDRIVE_REMOTE:$GDRIVE_PATH/releases/chromium-browser-${CHROMIUM_VERSION}.deb"
[ "$BUILD_TARGET" = "all" ] || [ "$BUILD_TARGET" = "win" ] && echo "  Windows : $GDRIVE_REMOTE:$GDRIVE_PATH/releases/mini_installer-${CHROMIUM_VERSION}.exe"
if [ -n "$HETZNER_API" ]; then
    echo "  💥 API TOKEN SET: server will SELF-DESTRUCT on successful build."
else
    echo "  ⚠️  No API token: you must delete the server manually when done."
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
BUILD_TARGET="$BUILD_TARGET"
SHALLOW_CLONE="$SHALLOW_CLONE"
TOOLCHAIN_HASH="42b5b0689e"
export TOOLCHAIN_PASS="$TOOLCHAIN_PASS"
EOF

# Part 2: script body — single-quoted so NO local expansion; all $VAR are remote
cat >> "$TMPSCRIPT" << 'SCRIPTEND'
CACHE_TARBALL="out-win-${PREV_VERSION}.tar.gz"

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
BUILD_CMD="./build-docker.sh $CHROMIUM_VERSION --target $BUILD_TARGET"
[ "$SHALLOW_CLONE" = "1" ] && BUILD_CMD="$BUILD_CMD --shallow"
if [ "$USE_CACHE" = "1" ] && [ -n "$PREV_VERSION" ]; then
    BUILD_CMD="./build-docker.sh $CHROMIUM_VERSION --from-cache $PREV_VERSION --target $BUILD_TARGET"
    [ "$SHALLOW_CLONE" = "1" ] && BUILD_CMD="$BUILD_CMD --shallow"
fi
echo "🏗️  Starting $BUILD_CMD ..."

BUILD_SUCCESS=0
EXE_UPLOADED=0
if $BUILD_CMD; then
    BUILD_SUCCESS=1
    echo ""
    echo "🎉 BUILD SUCCESS at $(date)"

    # ── Step 3a: Upload mini_installer.exe AND .deb FIRST ────────────────────
    # Must complete before server is deleted.
    EXE_NAME="mini_installer-${CHROMIUM_VERSION}.exe"
    DEB_NAME=$(ls /root/chromium-mv2/chromium-browser_*-${CHROMIUM_VERSION}.deb 2>/dev/null | head -n 1)
    
    echo ""
    echo "☁️  Uploading installers to ${GDRIVE_REMOTE}:${GDRIVE_PATH}/releases/ ..."
    
    if [ "$BUILD_TARGET" = "all" ] || [ "$BUILD_TARGET" = "win" ]; then
        if rclone copy "/root/chromium-mv2/${EXE_NAME}" "${GDRIVE_REMOTE}:${GDRIVE_PATH}/releases/" --progress; then
            echo "✅ Windows installer uploaded."
            EXE_UPLOADED=1
        else
            echo "⚠️  WARNING: Windows installer upload FAILED."
        fi
    else
        # For non-Windows builds, we mark this as 1 so self-destruct can proceed
        EXE_UPLOADED=1
    fi

    if [ "$BUILD_TARGET" = "all" ] || [ "$BUILD_TARGET" = "deb" ]; then
        if [ -n "$DEB_NAME" ]; then
            if rclone copy "$DEB_NAME" "${GDRIVE_REMOTE}:${GDRIVE_PATH}/releases/" --progress; then
                echo "✅ Debian package uploaded."
            else
                echo "⚠️  WARNING: Debian package upload FAILED."
            fi
        fi
    fi

    if [ "$EXE_UPLOADED" = "1" ]; then
        echo "✅ All installers ready at $(date)."
    else
        echo "⚠️  WARNING: One or more uploads failed. Server will NOT be deleted automatically."
    fi
else
    echo ""
    echo "❌ BUILD FAILED at $(date). See log above."
fi

# ── Step 4: Self-destruct (SUCCESS only) ─────────────────────────────────────
if [ -n "$HETZNER_API" ]; then
    SERVER_ID=$(curl -s http://169.254.169.254/hetzner/v1/metadata/instance-id)

    if [ "$BUILD_SUCCESS" = "0" ]; then
        echo ""
        echo "🛑 Build failed — server kept alive for debugging / retry."
        echo "   Fix the issue, then re-run:  bash /root/autonomous_build.sh"
        echo "   Delete manually when done:   Hetzner dashboard → delete server"
    elif [ "$EXE_UPLOADED" = "0" ]; then
        echo ""
        echo "🛑 Server NOT deleted — installer upload to Google Drive failed."
        echo "   Retrieve the file manually before deleting:"
        echo "     scp root@<SERVER_IP>:/root/chromium-mv2/mini_installer-${CHROMIUM_VERSION}.exe ./"
        echo "   Then delete the server from the Hetzner dashboard."
    else
        echo ""
        echo "💥 Self-destructing server (installer on GDrive)..."
        curl -sf -X DELETE -H "Authorization: Bearer $HETZNER_API" \
            "https://api.hetzner.cloud/v1/servers/${SERVER_ID}" && \
            echo "✅ Server deletion request sent." || \
            echo "⚠️  Self-destruct request failed — delete manually from Hetzner dashboard."
    fi
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

# Setup host-side RAM disk for build artifacts (out/) if high RAM is available.
# This allows 'out/' to persist across container failures/restarts on the same host.
TOTAL_MEM_KB=\$(awk '/MemTotal/{print \$2}' /proc/meminfo)
if [ "\$TOTAL_MEM_KB" -gt 128000000 ]; then
    echo "🚀 Ultra-High RAM detected (\${TOTAL_MEM_KB}KB), preparing 100GB host-side RAM disk..."
    mkdir -p /root/chromium-mv2/out_ramdisk
    if ! mountpoint -q /root/chromium-mv2/out_ramdisk; then
        mount -t tmpfs -o size=100G tmpfs /root/chromium-mv2/out_ramdisk || echo "⚠️ Failed to mount host RAM disk."
    fi
fi

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
echo "When done (success), download the installers from Google Drive:"
echo "  rclone copy $GDRIVE_REMOTE:$GDRIVE_PATH/releases/ ./"
echo ""
if [ -n "$HETZNER_API" ]; then
    echo "💥 API TOKEN DETECTED: server will SELF-DELETE on build success."
else
    echo "⚠️  NO API TOKEN: you MUST delete the server manually."
fi
echo "====================================================================="
EOF
