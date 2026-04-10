#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
GDRIVE_PATH="chromium-mv2-cache"
RCLONE_CONF="${HOME}/.config/rclone/rclone.conf"

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: ./build-win-on-hetzner-with-snapshots.sh <HETZNER_IP> <CHROMIUM_VERSION> [OPTIONS]"
    echo ""
    echo "  --from-cache <PREV>   Restore cached out/win/ from Google Drive before building."
    echo "                        Only needed on the very first run (no snapshot exists yet)."
    echo "  --api <TOKEN>         Hetzner API token. REQUIRED for snapshot+delete behaviour."
    echo "                        On both success AND failure the script will:"
    echo "                          1. Create a Hetzner snapshot of the server disk"
    echo "                             (preserves the full ~30 GB source tree + build artifacts"
    echo "                              in the Docker volume — avoids a 2-hour re-sync next time)"
    echo "                          2. Wait for the snapshot to finish"
    echo "                          3. Delete the server so you are not billed for idle time"
    echo ""
    echo "Snapshot workflow:"
    echo "  First run  : create a plain Hetzner server, run this script with --api <TOKEN>"
    echo "  Next runs  : create a new server from the last snapshot, run with --api <TOKEN>"
    echo "               (no --from-cache needed — source tree is already on the snapshot disk)"
    echo ""
    echo "Google Drive remote (default: 'gdrive'): GDRIVE_REMOTE=myname ./build-win-on-hetzner-with-snapshots.sh ..."
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
echo "Windows Chromium Build on Hetzner  [snapshot mode]"
echo "  Version : $CHROMIUM_VERSION"
if [ "$USE_CACHE" = "1" ]; then
    echo "  Cache   : $GDRIVE_REMOTE:$GDRIVE_PATH/out-win-${PREV_VERSION}.tar.gz  (download before build)"
fi
echo "  Exe     : $GDRIVE_REMOTE:$GDRIVE_PATH/releases/mini_installer-${CHROMIUM_VERSION}.exe  (upload on success)"
echo "  out/win/: preserved in Hetzner snapshot — no GDrive tarball needed"
if [ -n "$HETZNER_API" ]; then
    echo "  📸 API TOKEN SET: server will SNAPSHOT then SELF-DESTRUCT on successful build."
else
    echo "  ⚠️  No API token: no snapshot will be taken and you must delete the server manually."
fi
echo "Make sure your patches/ are saved locally! Press Enter to proceed (Ctrl+C to abort)."
read -rp "..."

# ── Ensure toolchain zip is on Google Drive (upload once, reuse forever) ──────
TOOLCHAIN_ZIP="$SCRIPT_DIR/42b5b0689e.zip"
TOOLCHAIN_GDRIVE_PATH="$GDRIVE_PATH/toolchain/42b5b0689e.zip"
if [ ! -f "$TOOLCHAIN_ZIP" ]; then
    echo "❌ Toolchain zip not found at $TOOLCHAIN_ZIP"
    exit 1
fi
echo ""
echo "🔍 Checking Google Drive for toolchain zip..."
if rclone lsf "$GDRIVE_REMOTE:$TOOLCHAIN_GDRIVE_PATH" > /dev/null 2>&1; then
    echo "✅ Toolchain zip already on Google Drive — skipping upload."
else
    echo "📤 Uploading toolchain zip to Google Drive (one-time, ~1.3 GB)..."
    rclone copy "$TOOLCHAIN_ZIP" "$GDRIVE_REMOTE:$GDRIVE_PATH/toolchain/" --progress
    echo "✅ Toolchain zip uploaded."
fi

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
EOF

# Part 2: script body — single-quoted so NO local expansion; all $VAR are remote
cat >> "$TMPSCRIPT" << 'SCRIPTEND'
CACHE_TARBALL="out-win-${PREV_VERSION}.tar.gz"

echo "======================================"
echo "Windows Chromium Build at $(date)"
echo "======================================"

cd /root/chromium-mv2

# ── Step 0: Ensure toolchain zip is present ──────────────────────────────────
# First run : downloaded from Google Drive at Hetzner network speed (~10s).
# Subsequent runs : already on disk from the snapshot — no download needed.
if [ ! -f "${TOOLCHAIN_HASH}.zip" ]; then
    echo ""
    echo "📥 Downloading toolchain zip from Google Drive (~1.3 GB)..."
    rclone copy "${GDRIVE_REMOTE}:${GDRIVE_PATH}/toolchain/${TOOLCHAIN_HASH}.zip" . --progress
    echo "✅ Toolchain zip ready (will be preserved in the next snapshot)."
else
    echo "✅ Toolchain zip already present (from snapshot)."
fi

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

BUILD_SUCCESS=0
EXE_UPLOADED=0
if $BUILD_CMD; then
    BUILD_SUCCESS=1
    echo ""
    echo "🎉 BUILD SUCCESS at $(date)"

    # ── Step 3a: Upload mini_installer.exe FIRST — must complete before server is deleted
    # The server will self-destruct after the snapshot; without this upload the user would
    # have to spin the server back up (full hourly charge) just to get a ~120 MB file.
    EXE_NAME="mini_installer-${CHROMIUM_VERSION}.exe"
    echo ""
    echo "☁️  Uploading ${EXE_NAME} to ${GDRIVE_REMOTE}:${GDRIVE_PATH}/releases/ ..."
    if rclone copy "/root/chromium-mv2/${EXE_NAME}" "${GDRIVE_REMOTE}:${GDRIVE_PATH}/releases/" --progress; then
        EXE_UPLOADED=1
        echo "✅ Installer uploaded at $(date)."
        echo "   Download: rclone copy ${GDRIVE_REMOTE}:${GDRIVE_PATH}/releases/${EXE_NAME} ./"
    else
        echo "⚠️  WARNING: installer upload FAILED at $(date)."
        echo "   The server will NOT be deleted until you retrieve the file manually."
        echo "   Retry: rclone copy ${GDRIVE_REMOTE}:${GDRIVE_PATH}/releases/${EXE_NAME} ./"
    fi

    # Step 3b skipped: out/win/ is preserved in the Hetzner snapshot.
    # No GDrive tarball needed — the snapshot is cheaper and faster than
    # archiving + uploading tens of GB just to restore them next time.
else
    echo ""
    echo "❌ BUILD FAILED at $(date). See log above."
fi

# ── Step 4: Snapshot + self-destruct (SUCCESS only) ──────────────────────────
# On build FAILURE the server is intentionally kept alive.  Reason: snapshotting
# then restoring costs at minimum one full billing hour ($0.708).  It is cheaper
# to leave the server running, fix the patch/issue interactively, and re-run
# /root/autonomous_build.sh directly — no restore charge at all.
#
# On SUCCESS the snapshot captures the entire server disk (Docker volume at
# /var/lib/docker/volumes/chromium-mv2-src/) preserving the full ~30 GB source
# tree + build artifacts.  The next weekly build restores from this snapshot and
# skips the 2-hour gclient sync entirely.
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
        # Build succeeded AND exe is safely on GDrive — snapshot then delete.
        SNAPSHOT_DESC="chromium-mv2-${CHROMIUM_VERSION}-$(date +%Y%m%d)"
        echo ""
        echo "📸 Creating Hetzner snapshot: \"${SNAPSHOT_DESC}\" ..."
        echo "   (Preserves source tree + build volume for the next incremental build)"
        SNAPSHOT_RESPONSE=$(curl -sf -X POST \
            -H "Authorization: Bearer $HETZNER_API" \
            -H "Content-Type: application/json" \
            -d "{\"description\": \"${SNAPSHOT_DESC}\", \"type\": \"snapshot\"}" \
            "https://api.hetzner.cloud/v1/servers/${SERVER_ID}/actions/create_image" || echo "{}")

        ACTION_ID=$(echo "$SNAPSHOT_RESPONSE" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('action',{}).get('id',''))" 2>/dev/null || true)
        IMAGE_ID=$(echo "$SNAPSHOT_RESPONSE" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('image',{}).get('id',''))" 2>/dev/null || true)

        if [ -n "$ACTION_ID" ]; then
            echo "⏳ Waiting for snapshot to finish (action ${ACTION_ID}, up to 20 min)..."
            SNAP_OK=0
            for i in $(seq 1 120); do   # 120 × 10 s = 20 minutes max
                STATUS=$(curl -sf \
                    -H "Authorization: Bearer $HETZNER_API" \
                    "https://api.hetzner.cloud/v1/actions/${ACTION_ID}" | \
                    python3 -c "import sys,json; print(json.load(sys.stdin)['action']['status'])" \
                    2>/dev/null || echo "error")
                if [ "$STATUS" = "success" ]; then
                    SNAP_OK=1
                    echo "✅ Snapshot ready (image id: ${IMAGE_ID})."
                    echo "   ➡  Next build: create a Hetzner server from image ${IMAGE_ID}"
                    echo "      then run: ./build-win-on-hetzner-with-snapshots.sh <NEW_IP> <NEW_VER> --api <TOKEN>"
                    break
                elif [ "$STATUS" = "error" ]; then
                    echo "⚠️  Snapshot action reported an error — skipping deletion to preserve data."
                    echo "   Delete the server manually from the Hetzner dashboard when ready."
                    break
                fi
                echo "   ... snapshot progress check ${i}/120 (status: ${STATUS})"
                sleep 10
            done
            if [ "$SNAP_OK" = "0" ] && [ "$STATUS" != "error" ]; then
                echo "⚠️  Snapshot did not finish within 20 minutes."
                echo "   Check Hetzner dashboard for image status before deleting the server."
            fi
        else
            echo "⚠️  Could not parse snapshot action id from API response."
            echo "   Response: $SNAPSHOT_RESPONSE"
            echo "   Skipping deletion — check Hetzner dashboard manually."
        fi

        if [ "$SNAP_OK" = "1" ]; then
            echo ""
            echo "💥 Self-destructing server (snapshot safe, installer on GDrive)..."
            curl -sf -X DELETE -H "Authorization: Bearer $HETZNER_API" \
                "https://api.hetzner.cloud/v1/servers/${SERVER_ID}" && \
                echo "✅ Server deletion request sent." || \
                echo "⚠️  Self-destruct request failed — delete manually from Hetzner dashboard."
        fi
    fi
fi
SCRIPTEND

chmod +x "$TMPSCRIPT"

# ── Sync files and script to Hetzner ─────────────────────────────────────────
echo ""
echo "🚀 Preparing Hetzner ($HETZNER_IP)..."
ssh $SSH_OPTS root@$HETZNER_IP "mkdir -p /root/chromium-mv2"

echo "📤 Synchronizing build scripts and patches (toolchain zip excluded — fetched from GDrive)..."
rsync -a -e "ssh $SSH_OPTS" --info=progress2 \
    --exclude='.git*' \
    --exclude='out' \
    --exclude='*.exe' \
    --exclude='42b5b0689e.zip' \
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

echo "⚙️ Swap setup..."
if [ ! -f /swapfile ]; then
    fallocate -l 16G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo "✅ 16GB swap enabled."
else
    echo "✅ Swap exists."
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
echo "When done (success), download the installer:"
echo "  rclone copy $GDRIVE_REMOTE:$GDRIVE_PATH/releases/mini_installer-$CHROMIUM_VERSION.exe ./"
echo ""
if [ -n "$HETZNER_API" ]; then
    echo "📸 API TOKEN DETECTED: server will SNAPSHOT itself then SELF-DELETE"
    echo "   on BOTH build success and failure."
    echo "   Cost: snapshot ~\$0.0199/GB/month — far cheaper than idle server time."
else
    echo "⚠️  NO API TOKEN: no snapshot will be taken."
    echo "   You MUST delete the server manually from the Hetzner dashboard."
fi
echo "====================================================================="
EOF
