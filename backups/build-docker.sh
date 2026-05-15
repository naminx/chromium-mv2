#!/usr/bin/env bash
# build-docker.sh — The Chromium Build Engine (Proven Single Source)
#
# This script is a Two-Phase State Machine:
# PHASE 1: Host-Side Preparation (Sync, Toolchains, Memory Resilience)
# PHASE 2: Container-Side Compilation (Patches, GN, Ninja)
set -e

# --- Configuration ---
IMAGE_NAME="chromium-mv2-builder-v13"
VOLUME_NAME="${VOLUME_NAME:-chromium-mv2-src}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect and set local timezone for logging
export TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "UTC")

# Enable logging with timestamps if running on host
if [ ! -f /.dockerenv ]; then
    LOG_FILE="build.log"
    if command -v ts >/dev/null 2>&1; then
        exec > >(ts '[%Y-%m-%d %H:%M:%S]' | tee "$LOG_FILE") 2>&1
    else
        exec > >(tee "$LOG_FILE") 2>&1
    fi
    echo "--- Build Script Started on Host ---"
fi

usage() {
    echo "Usage: $0 <VERSION> [--target <deb|win|all>] [--setup-only] [--no-release] [--full-sync] [--clean]"
    exit 1
}

if [ -z "$1" ] || [[ "$1" == -* ]]; then usage; fi
CHROMIUM_VERSION="$1"; BUILD_TARGET="all"; SETUP_ONLY="0"; REFRESH_ONLY="0"; NO_RELEASE="${NO_RELEASE:-0}"; FULL_SYNC="0"; CLEAN_BUILD="0"
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --target) BUILD_TARGET="$2"; shift 2 ;;
        --setup-only) SETUP_ONLY="1"; shift ;;
        --no-release) NO_RELEASE="1"; shift ;;
        --full-sync) FULL_SYNC="1"; shift ;;
        --clean) CLEAN_BUILD="1"; shift ;;
        --refresh-patches-only) REFRESH_ONLY="1"; shift ;;
        --shallow) shift ;; # Legacy
        *) shift ;;
    esac
done

# ── PHASE 1: Data Preparation (Runs on Host for Speed) ───────────────────────
if [ ! -f /.dockerenv ]; then
    # 1.1 Ensure Docker Image exists
    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo "🔨 Building base image..."
        docker build --tag "$IMAGE_NAME" - << 'DOCKERFILE'
FROM docker.io/library/ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN <<APT
apt-get update && apt-get install -y --no-install-recommends \
    git curl wget sudo lsb-release file ca-certificates \
    python3 python-is-python3 python3-httplib2 \
    tzdata \
    fuse libfuse2 ciopfs unzip p7zip-full pkg-config binutils rpm dpkg-dev patch gperf git-restore-mtime \
    devscripts fakeroot moreutils software-properties-common less && \
add-apt-repository ppa:neovim-ppa/unstable -y && \
apt-get update && apt-get install -y --no-install-recommends \
    fish neovim ripgrep fd-find bat && rm -rf /var/lib/apt/lists/*
APT
RUN <<EZA
mkdir -p /etc/apt/keyrings
wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" | tee /etc/apt/sources.list.d/gierens.list
apt-get update && apt-get install -y eza && rm -rf /var/lib/apt/lists/*
EZA
RUN ln -s /usr/bin/fdfind /usr/local/bin/fd && ln -s /usr/bin/batcat /usr/local/bin/bat
RUN <<GH
mkdir -p /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*
GH
RUN <<APT
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git /depot_tools
APT
ENV PATH="/depot_tools:$PATH"
RUN DEPOT_TOOLS_METRICS=0 /depot_tools/update_depot_tools
ENV DEPOT_TOOLS_UPDATE=0
ENV DEPOT_TOOLS_METRICS=0
WORKDIR /chromium
DOCKERFILE
    fi

    # 1.2 Host-Side Sync (EXACT REPRODUCTION OF PROVEN MONOLITH)
    IS_DOCKER_VOLUME=0
    if docker volume inspect "$VOLUME_NAME" &>/dev/null; then
        IS_DOCKER_VOLUME=1
        echo "📦 Detected Docker Volume: $VOLUME_NAME"
    fi

    if [ "$IS_DOCKER_VOLUME" = "0" ]; then
        cd "$VOLUME_NAME"
        if [ "$SKIP_GCLIENT_SYNC" != "1" ]; then
            if [ ! -d "depot_tools" ]; then 
                echo "📥 Installing depot_tools..."
                git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git depot_tools
            fi
            export PATH="$(pwd)/depot_tools:$PATH"
            export GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1

            echo "📝 Configuring Universal .gclient..."
            cat > .gclient << 'PYTHON'
solutions = [ { "name": "src", "url": "https://chromium.googlesource.com/chromium/src.git", "managed": False, "custom_deps": {}, "custom_vars": {}, } ]
target_os = ["win", "linux"]
PYTHON

            # THE FAST PATH (WHY): Raw git clone --progress is the only way to get a
            # scrolling status light in the terminal. gclient sync is silent for 
            # the first 30GB, which looks like a hang in cloud logs.
            GIT_DEPTH="--depth 1"
            [ "$FULL_SYNC" = "1" ] && GIT_DEPTH=""
            
            if [ ! -d "src" ]; then 
                echo "🚀 Performing high-speed manual clone of src tag $CHROMIUM_VERSION..."
                git clone $GIT_DEPTH --branch "$CHROMIUM_VERSION" --progress https://chromium.googlesource.com/chromium/src.git
            else 
                echo "🚀 Performing high-speed manual fetch of src tag $CHROMIUM_VERSION..."
                git -C src reset --hard HEAD 2>/dev/null || true
                git -C src clean -fd 2>/dev/null || true
                git -C src fetch origin "refs/tags/$CHROMIUM_VERSION" $GIT_DEPTH --progress && git -C src checkout FETCH_HEAD
            fi

            echo "📥 Syncing dependencies (Universal)..."
            # EXACT FLAGS from backups/build-hetzner.sh
            # Added -D to reclaim disk space by removing orphaned directories
            GCLIENT_SYNC_FLAGS="-D --nohooks --verbose -j$(nproc)"
            if [ "$FULL_SYNC" = "0" ]; then
                GCLIENT_SYNC_FLAGS="$GCLIENT_SYNC_FLAGS --no-history --shallow"
            fi
            gclient sync $GCLIENT_SYNC_FLAGS
            
            # 1.3 SAFE TOOLCHAIN SEQUENCE (WHY):
            # We MUST set WIN_TOOLCHAIN=0 during runhooks to prevent 401 Unauthorized
            # errors from Google's private SDK storage. We then manually update clang.
            echo "🛠️  Updating gclient hooks..."
            export DEPOT_TOOLS_WIN_TOOLCHAIN=0
            gclient runhooks
            echo "🔧 Updating Clang..."
            python3 src/tools/clang/scripts/update.py
        fi
        if [ "$SETUP_ONLY" = "1" ]; then echo "✅ Setup Complete. Volume is Warm."; exit 0; fi
    else
        echo "⏭️ Skipping host-side sync for Docker Volume."
    fi

    # ── Patch Refresh Mode (Host Only) ───────────────────────────────────────
    if [ "$REFRESH_ONLY" = "1" ]; then
        [ "$IS_DOCKER_VOLUME" = "1" ] && { echo "❌ --refresh-patches-only not supported with Docker Volumes yet."; exit 1; }
        REFRESH_VERSION="$CHROMIUM_VERSION"
        PATCHES_DIR="${SCRIPT_DIR}/patches"
        SRC_DIR="$VOLUME_NAME/src"
        [ -d "$SRC_DIR/.git" ] || { echo "❌ No src/.git found. Run a sync first."; exit 1; }

        echo "🔄 Refreshing patches for Chromium $REFRESH_VERSION..."

        # Collect all files touched by our patches
        TOUCHED=$(for p in "$PATCHES_DIR"/*.patch; do
            grep '^+++ b/' "$p" | sed 's|^+++ b/||'
        done | sort -u)
        echo "📋 Files affected by patches:"; echo "$TOUCHED" | sed 's/^/  /'

        cd "$SRC_DIR"
        echo "📥 Sparse-fetching $REFRESH_VERSION (no build will run)..."
        git fetch origin "refs/tags/$REFRESH_VERSION" --depth=1 --no-tags --quiet

        FAILED=0
        for p in "$PATCHES_DIR"/*.patch; do
            [ -f "$p" ] || continue
            PNAME=$(basename "$p")
            # Files this specific patch touches
            P_FILES=$(grep '^+++ b/' "$p" | sed 's|^+++ b/||' | tr '\n' ' ')

            # Stage the new version as the baseline for this patch's files
            git checkout FETCH_HEAD -- $P_FILES 2>/dev/null

            echo -n "  🩹 $PNAME ... "
            # Try clean apply to index only (WT stays at new-version baseline)
            if git apply --cached "$p" 2>/dev/null; then
                MODE="clean"
            elif git apply --cached --3way "$p" 2>/dev/null; then
                MODE="3way"
            else
                MODE="fail"
            fi

            if [ "$MODE" != "fail" ]; then
                # Write patched index back to WT so we can diff vs FETCH_HEAD
                git checkout-index -f -- $P_FILES
                # FETCH_HEAD (baseline) vs WT (patched) = the refreshed patch
                git diff FETCH_HEAD -- $P_FILES > "$p"
                # Restore WT and index to new-version baseline
                git checkout FETCH_HEAD -- $P_FILES 2>/dev/null
                echo "✅ ($MODE)"
            else
                # Apply with 3way to get conflict markers in WT for manual fix
                git apply --3way "$p" 2>/dev/null || true
                echo "❌ CONFLICT — fix manually in:"
                echo "     $SRC_DIR/$P_FILES"
                echo "     Then: cd $SRC_DIR && git diff FETCH_HEAD -- $P_FILES > $p && git checkout FETCH_HEAD -- $P_FILES"
                FAILED=$((FAILED+1))
            fi
        done

        # Restore src to a clean baseline state
        git checkout FETCH_HEAD -- $TOUCHED 2>/dev/null || true

        [ "$FAILED" -gt 0 ] && echo "❌ $FAILED patch(es) need manual fixing." && exit 1
        echo "✅ All patches refreshed. Verify the diffs in ${PATCHES_DIR}/ before committing."
        exit 0
    fi

    # 1.4 Recurse into Docker
    echo "🚀 Launching build engine..."
    MOUNT_SRC="$(pwd)"
    [ "$IS_DOCKER_VOLUME" = "1" ] && MOUNT_SRC="$VOLUME_NAME"

    # Forward relevant flags
    EXTRA_ARGS=""
    [ "$SETUP_ONLY" = "1" ] && EXTRA_ARGS="$EXTRA_ARGS --setup-only"
    [ "$NO_RELEASE" = "1" ] && EXTRA_ARGS="$EXTRA_ARGS --no-release"
    [ "$FULL_SYNC" = "1" ] && EXTRA_ARGS="$EXTRA_ARGS --full-sync"
    [ "$CLEAN_BUILD" = "1" ] && EXTRA_ARGS="$EXTRA_ARGS --clean"

    docker run --rm -i \
        --ulimit nofile=65536:65536 \
        --network host --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor:unconfined \
        -v "$MOUNT_SRC:/chromium" \
        -v "${SCRIPT_DIR}:/host_scripts" \
        -v "${SCRIPT_DIR}/patches:/patches:ro" \
        -v "${SCRIPT_DIR}:/host_out" \
        $( [ -d "${SCRIPT_DIR}/out_ramdisk" ] && echo "-v ${SCRIPT_DIR}/out_ramdisk:/chromium/src/out" ) \
        -e "VOLUME_NAME=/chromium" \
        -e "VPYTHON_VENV_ROOT=/chromium/.cache/vpython" \
        -e "PIP_CACHE_DIR=/chromium/.cache/pip" \
        -e "HETZNER_TOKEN=${HETZNER_TOKEN}" \
        -e "GITHUB_TOKEN=${GITHUB_TOKEN}" \
        -e "TZ=${TZ}" \
        -e "CHROMIUM_MV2_API_KEY=${CHROMIUM_MV2_API_KEY}" \
        -e "CHROMIUM_MV2_CLIENT_ID=${CHROMIUM_MV2_CLIENT_ID}" \
        -e "CHROMIUM_MV2_CLIENT_SECRET=${CHROMIUM_MV2_CLIENT_SECRET}" \
        -e "SDK_VER=${SDK_VER}" \
        -e "SETUP_ONLY=${SETUP_ONLY}" \
        -e "NO_RELEASE=${NO_RELEASE}" \
        -e "FULL_SYNC=${FULL_SYNC}" \
        -e "CLEAN_BUILD=${CLEAN_BUILD}" \
        -e "IS_LOCAL_BUILD=${IS_DOCKER_VOLUME}" \
        "$IMAGE_NAME" bash "/host_scripts/$(basename "$0")" "$CHROMIUM_VERSION" --target "$BUILD_TARGET" $EXTRA_ARGS
    exit $?
fi

# ── PHASE 2: Compilation (Runs inside Container) ─────────────────────────────
set -e
# Enable logging with timestamps (requires moreutils)
if command -v ts >/dev/null 2>&1; then
    exec > >(ts '[%Y-%m-%d %H:%M:%S]') 2>&1
fi
echo "--- Build Script Started inside Container ---"

# --- Constants ---
HASH="e66617bc68"
# SDK_VER is used for downloading the toolchain if needed
[ -z "$SDK_VER" ] && SDK_VER="10.0.26100.0"

do_release() {
    local TGT="$1"
    if [ "$NO_RELEASE" = "1" ]; then echo "⏭️ Skipping release upload."; return 0; fi
    if [ -z "$GITHUB_TOKEN" ]; then echo "⚠️ GITHUB_TOKEN not set. Skipping upload."; return 0; fi
    export GH_TOKEN="$GITHUB_TOKEN"

    local REL_TITLE="Chromium $CHROMIUM_VERSION"
    local REL_NOTES="Release for Chromium $CHROMIUM_VERSION (MV2 Support)"
    local FILES=""
    
    if [ "$TGT" = "win" ]; then
        REL_TITLE="Chromium $CHROMIUM_VERSION for Windows"
        REL_NOTES="Release for Chromium $CHROMIUM_VERSION (MV2 Support) for Windows"
        # Look for both the standard name and our versioned name
        FILES=$(ls out/win/mini_installer.exe 2>/dev/null || true)
    elif [ "$TGT" = "deb" ]; then
        REL_TITLE="Chromium $CHROMIUM_VERSION for Linux"
        REL_NOTES="Release for Chromium $CHROMIUM_VERSION (MV2 Support) for Linux"
        FILES=$(ls out/linux/chromium-browser-stable_*.deb 2>/dev/null || true)
    fi

    if [ -n "$FILES" ]; then
        echo "🚀 Uploading $TGT artifacts to GitHub..."
        # Try to upload to existing release first, create if fails
        gh release upload "v$CHROMIUM_VERSION" $FILES --clobber --repo naminx/chromium-mv2 2>/dev/null \
            || gh release create "v$CHROMIUM_VERSION" $FILES --repo naminx/chromium-mv2 --title "$REL_TITLE" --notes "$REL_NOTES"
    else
        echo "⚠️ No $TGT files found to release."
    fi
}

cd "$VOLUME_NAME"
export PATH="/depot_tools:$PATH"
export GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1
ulimit -n 65536 || true

# 2.0 Container-Side Sync (For Docker Volumes)
# ⚠️ Smart Sync: We skip the massive source/gclient sync and hooks if already done.
SYNC_V_FILE=".last_sync_version"
LAST_SYNC_V=""
[ -f "$SYNC_V_FILE" ] && LAST_SYNC_V=$(cat "$SYNC_V_FILE")

if [ "$LAST_SYNC_V" = "$CHROMIUM_VERSION" ] && [ "$FULL_SYNC" = "0" ] && [ "$CLEAN_BUILD" = "0" ] && [ -d "src" ]; then
    echo "⏭️  Smart Sync: Version $CHROMIUM_VERSION already synced. Skipping source, gclient, and Clang updates."
else
    GIT_DEPTH="--depth 1"
    [ "$FULL_SYNC" = "1" ] && GIT_DEPTH=""

    # Incremental Fetch with Timestamp Preservation
    if [ ! -d "src" ]; then 
        echo "🚀 Performing high-speed manual clone of src tag $CHROMIUM_VERSION..."
        git clone $GIT_DEPTH --branch "$CHROMIUM_VERSION" --progress https://chromium.googlesource.com/chromium/src.git
    else 
        # Use .last_built_version as the baseline for the fetch-bump logic
        CURRENT_V=""
        [ -f .last_built_version ] && CURRENT_V=$(cat .last_built_version)
        if [ "$CURRENT_V" != "$CHROMIUM_VERSION" ]; then
            echo "🚀 Fetching src tag $CHROMIUM_VERSION..."
            cd src
            git reset --hard HEAD 2>/dev/null || true
            git clean -fd 2>/dev/null || true
            git fetch origin "refs/tags/$CHROMIUM_VERSION" $GIT_DEPTH --progress
            if [ -n "$CURRENT_V" ] && git rev-parse "$CURRENT_V" >/dev/null 2>&1; then
                echo "🕐 Identifying changed files to preserve timestamps..."
                git -c diff.renameLimit=20000 diff --name-only --diff-filter=d "$CURRENT_V" "FETCH_HEAD" > /tmp/changed_files.txt
            fi
            git checkout FETCH_HEAD
            if [ -s /tmp/changed_files.txt ]; then
                echo "🕐 Restoring timestamps for unchanged files..."
                tr '\n' '\0' < /tmp/changed_files.txt | xargs -0 -r touch -c || true
                rm -f /tmp/changed_files.txt
            fi
            cd ..
        fi
    fi

    echo "📥 Syncing dependencies (Universal)..."
    GCLIENT_SYNC_FLAGS="-D --nohooks --verbose -j$(nproc)"
    [ "$FULL_SYNC" = "0" ] && GCLIENT_SYNC_FLAGS="$GCLIENT_SYNC_FLAGS --no-history --shallow"
    gclient sync $GCLIENT_SYNC_FLAGS
    
    echo "🛠️  Updating gclient hooks..."
    export DEPOT_TOOLS_WIN_TOOLCHAIN=0
    gclient runhooks
    echo "🔧 Updating Clang..."
    python3 src/tools/clang/scripts/update.py
    
    # Mark sync as successful
    echo "$CHROMIUM_VERSION" > "$SYNC_V_FILE"
fi

if [ "$SETUP_ONLY" = "1" ]; then echo "✅ Setup Complete. Volume is Warm."; exit 0; fi

# 2.1 CLEAN AND PATCH FIRST (WHY):
# ⚠️ CAUTION: The order and logic here are critical for INCREMENTAL BUILDS.
# 1. 'git reset' is necessary to remove previous toolchain 'sed' hacks, but it wipes mtimes.
# 2. Ninja uses mtimes to decide what to build. If we reset without restoration,
#    we lose 100+ CPU hours of progress (60k+ targets).
# 3. 'vs_toolchain.py' MUST be stubbed (Update -> return 0) because 'gn gen' calls it.
#    If it's not stubbed, 'gn' will trigger a toolchain download that fails on Linux.
cd src
echo "🧹 Cleaning and Patching..."

if [ "$CLEAN_BUILD" = "1" ]; then
    echo "🗑️  Performing clean build (wiping out/)..."
    rm -rf out/*
fi

# Incremental build protection: Use state hash to avoid touching files unnecessarily
# Added $0 (this script) to the hash so changes to patching logic trigger a re-patch
PATCH_HASH=$(echo "$CHROMIUM_VERSION-$FULL_SYNC" $(md5sum /patches/*.patch 2>/dev/null | md5sum) $(md5sum $0 | md5sum) | md5sum | cut -d' ' -f1 || echo "no-patches")
STATE_FILE="$VOLUME_NAME/.last_patch_state"
CURRENT_STATE="$PATCH_HASH"
LAST_STATE=""
[ -f "$STATE_FILE" ] && LAST_STATE=$(cat "$STATE_FILE")

    if [ "$CURRENT_STATE" != "$LAST_STATE" ] || [ "$CLEAN_BUILD" = "1" ]; then
        echo "🔄 Change detected (Version/Patches/SyncMode/BuildScript). Resetting and re-patching..."
        
        # PRESERVE TIMESTAMPS (WHY): 
        # Ninja compares Source MTime vs Object MTime.
        # After 'git reset', all source files look "newer" than the 60k object files in out/.
        # We use a 'sentinel' to identify the 'past'.
        SENTINEL="/tmp/last_build_sentinel"
        rm -f "$SENTINEL"
        if [ -f "$VOLUME_NAME/.last_built_version" ]; then touch -r "$VOLUME_NAME/.last_built_version" "$SENTINEL"
        elif [ -f out/linux/build.ninja ]; then touch -r out/linux/build.ninja "$SENTINEL"
        elif [ -f out/win/build.ninja ]; then touch -r out/win/build.ninja "$SENTINEL"
        fi

        # 🚀 RECOVERY LOGIC: If the sentinel we found is too "new" (less than 1 hour old),
        # it means the build already started and poisoned the mtime.
        # We search for the OLDEST .obj file in the build directory to find the "True Past".
        NOW_S=$(date +%s)
        SENTINEL_S=$(date -r "$SENTINEL" +%s 2>/dev/null || echo 0)
        DIFF_S=$(( NOW_S - SENTINEL_S ))
        
        if [ "$DIFF_S" -lt 3600 ] && [ "$CLEAN_BUILD" = "0" ]; then
            echo "🔍 Sentinel is too new ($((DIFF_S/60))m old). Searching for recovery sentinel..."
            # Find the oldest .obj file that is at least 1 hour old
            TRUE_PAST=$(find out/ -name "*.obj" -mmin +60 -printf "%T+ %p\n" 2>/dev/null | sort | head -n 1 | awk '{print $2}')
            if [ -n "$TRUE_PAST" ] && [ -f "$TRUE_PAST" ]; then
                echo "🚑 Recovery Sentinel Found: $(basename "$TRUE_PAST") ($(date -r "$TRUE_PAST"))"
                touch -r "$TRUE_PAST" "$SENTINEL"
            else
                echo "⚠️ No old object files found for recovery. Will use current sentinel."
            fi
        fi

        # 1. Identify files that were already dirty or changed since last build
        EXCLUDE_LIST="/tmp/exclude_files.txt"
        : > "$EXCLUDE_LIST"
        if [ -f "$SENTINEL" ]; then
            echo "🕐 Identifying files changed since last build..."
            # Files newer than sentinel (e.g. from gclient sync)
            find . \( -path ./out -o -path ./.git \) -prune -o -type f -newer "$SENTINEL" -printf "%P\n" >> "$EXCLUDE_LIST"
            # Files currently modified in WT
            git status --porcelain | sed 's/^...//;s/.* -> //' >> "$EXCLUDE_LIST"
        fi

        # The Nuke
        echo "🧹 Performing git reset --hard..."
        git reset --hard HEAD 2>/dev/null || true
        # ⚠️ CRITICAL: Ensure out/ is NEVER nuked. 
        git clean -fd -e out/ 2>/dev/null || true
        
        echo "🩹 Applying patches..."
        for p in /patches/*.patch; do
            [ -f "$p" ] || continue
            echo "  🩹 Applying: $(basename "$p")"
            git apply "$p"
            # Add patched files to exclude list to ensure they ARE recompiled
            git apply --numstat "$p" | awk '{print $3}' >> "$EXCLUDE_LIST"
        done

        if [ -n "$CHROMIUM_MV2_API_KEY" ]; then
            echo "🔑 Injecting private API keys..."
            sed -i "s/CUSTOM_GOOGLE_API_KEY_PLACEHOLDER/$CHROMIUM_MV2_API_KEY/g" google_apis/default_api_keys.h 2>/dev/null || true
            sed -i "s/CUSTOM_GOOGLE_CLIENT_ID_PLACEHOLDER/$CHROMIUM_MV2_CLIENT_ID/g" google_apis/default_api_keys.h 2>/dev/null || true
            sed -i "s/CUSTOM_GOOGLE_CLIENT_SECRET_PLACEHOLDER/$CHROMIUM_MV2_CLIENT_SECRET/g" google_apis/default_api_keys.h 2>/dev/null || true
            echo "google_apis/default_api_keys.h" >> "$EXCLUDE_LIST"
        fi

        # 2.3.2 THE DOUBLE SPOOF (WHY):
        # ⚠️ CAUTION: 'gn gen' calls vs_toolchain.py. If we don't return 0 in Update(),
        # it attempts to download the SDK from Google servers, which will fail here.
        if [ -f build/vs_toolchain.py ]; then
            echo "🩹 Force-patching vs_toolchain.py..."
            # Stub out the Update function to prevent it from calling external scripts
            sed -i "/def Update(/a \  return 0" build/vs_toolchain.py
            # Ensure the hash and version match our environment
            sed -i "s/TOOLCHAIN_HASH = .*/TOOLCHAIN_HASH = '$HASH'/g" build/vs_toolchain.py
            sed -i "s/SDK_VERSION = .*/SDK_VERSION = '10.0.26100.0'/g" build/vs_toolchain.py
            # Force it to think the environment is always correct
            sed -i "s/return version != env_version/return False/g" build/vs_toolchain.py
            # ⚠️ We do NOT add this to EXCLUDE_LIST because we don't want Ninja
            # to see it as "new" and trigger a 6-hour full build regeneration.
        fi

        # RESTORE TIMESTAMPS (THE MAGIC):
        # This is the "Hardened Incremental" logic. We reset the mtime of every 
        # UNCHANGED file back to the 'past' (the sentinel). This tricks Ninja into
        # reusing the 60,000+ .o files in out/.
        if [ -f "$SENTINEL" ] && [ "$CLEAN_BUILD" = "0" ]; then
            echo "🕐 Restoring timestamps for unchanged files to preserve incremental build..."
            sort -u "$EXCLUDE_LIST" -o "$EXCLUDE_LIST"
            
            # Every file NOT in EXCLUDE_LIST gets the SENTINEL time (the past)
            find . \( -path ./out -o -path ./.git \) -prune -o -type f -printf "%P\n" | \
                grep -v -F -x -f "$EXCLUDE_LIST" | \
                tr '\n' '\0' | xargs -0 -r touch -h -r "$SENTINEL"
            
            # Special Case: Explicitly touch vs_toolchain.py to the past even if it was modified
            [ -f build/vs_toolchain.py ] && touch -h -r "$SENTINEL" build/vs_toolchain.py
            
            echo "✅ Timestamps restored. Ninja should now perform an incremental build."
        fi
        rm -f "$EXCLUDE_LIST"

        echo "$CURRENT_STATE" > "$STATE_FILE"
    else
        echo "✅ Already patched and injected for $CHROMIUM_VERSION. Skipping to preserve timestamps."
    fi

# 2.2 Legacy Intelligence (Removed - Integrated above)


# 2.3 Windows Toolchain Configuration (PROVEN METHOD)
if [ "$BUILD_TARGET" = "win" ] || [ "$BUILD_TARGET" = "all" ]; then
    TOOLCHAIN_ROOT="$VOLUME_NAME/win_toolchain"; TOOLCHAIN_DEST="$TOOLCHAIN_ROOT/vs_files/$HASH"
    
    # 2.3.1 ciopfs Mount (WHY):
    # Windows headers use MixedCase. Linux is case-sensitive. ciopfs emulates
    # a case-insensitive disk so clang can find 'Windows.h'. We check mountpoint
    # first because double-mounting FUSE can hang the kernel.
    if ! mountpoint -q "$TOOLCHAIN_ROOT/vs_files"; then
        mkdir -p "$TOOLCHAIN_ROOT/vs_files.ciopfs" "$TOOLCHAIN_ROOT/vs_files"
        echo "📂 Mounting case-insensitive toolchain filesystem..."
        ciopfs -o use_ino "$TOOLCHAIN_ROOT/vs_files.ciopfs" "$TOOLCHAIN_ROOT/vs_files" || true
    fi

    if [ ! -f "$TOOLCHAIN_DEST/vs_version" ]; then
        echo "📂 Preparing Windows toolchain (7z)..."
        mkdir -p "$TOOLCHAIN_DEST"
        if [ ! -f "$VOLUME_NAME/$HASH.7z" ]; then
            echo "  📥 Downloading toolchain archive..."
            curl -L -o "$VOLUME_NAME/$HASH.7z" "https://github.com/naminx/chromium-mv2/releases/download/$SDK_VER/$HASH.7z"
        fi
        echo "  📦 Extracting toolchain..."
        # WHY: We use the GITHUB_TOKEN as the password to prevent redistribution.
        7z x -p"${GITHUB_TOKEN}" "$VOLUME_NAME/$HASH.7z" -o"$TOOLCHAIN_DEST"
    fi
    
    # ── THE PROVEN OVERRIDES ──
    # WHY: These variables and JSON values force Chromium to use our mounted 
    # folder instead of attempting a GCS download.
    export GYP_MSVS_OVERRIDE_PATH="$TOOLCHAIN_DEST"
    export WINDOWSSDKDIR="$TOOLCHAIN_DEST/windows kits/10"
    mkdir -p /depot_tools/win_toolchain && ln -sfn "$TOOLCHAIN_ROOT/vs_files" /depot_tools/win_toolchain/vs_files
    
    mkdir -p build
    cat > build/win_toolchain.json << JSON
{
  "path": "$TOOLCHAIN_DEST",
  "version": "$HASH",
  "win_sdk": "$TOOLCHAIN_DEST/windows kits/10",
  "wdk": "$TOOLCHAIN_DEST/wdk",
  "runtime_dirs": [
    "$TOOLCHAIN_DEST/sys64",
    "$TOOLCHAIN_DEST/sys32",
    "$TOOLCHAIN_DEST/sysarm64"
  ]
}
JSON

    # ⚠️ CRITICAL: We must touch this to the past to avoid Ninja regeneration.
    SENTINEL="/tmp/last_build_sentinel"
    [ -f "$SENTINEL" ] && touch -r "$SENTINEL" build/win_toolchain.json

    # Switch to 1 so 'gn gen' sees the toolchain is ready
    export DEPOT_TOOLS_WIN_TOOLCHAIN=1
else
    export DEPOT_TOOLS_WIN_TOOLCHAIN=0
fi

# 2.4 Resources and Build
CPU_COUNT=$(nproc); TOTAL_MEM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
NINJA_JOBS=$(( TOTAL_MEM_GB / 2 )); [ "$NINJA_JOBS" -lt 1 ] && NINJA_JOBS=1
[ "$NINJA_JOBS" -gt "$CPU_COUNT" ] && NINJA_JOBS=$CPU_COUNT
CONCURRENT_LINKS=$(( TOTAL_MEM_GB / 16 )); [ "$CONCURRENT_LINKS" -lt 1 ] && CONCURRENT_LINKS=1

if [ "$BUILD_TARGET" = "deb" ] || [ "$BUILD_TARGET" = "all" ]; then
    echo "🔨 Building Linux Debian package..."
    mkdir -p out/linux
    # WHY: chrome_pgo_phase=0 is mandatory to skip missing Google performance profiles.
    ARGS="is_official_build=true symbol_level=0 target_os=\"linux\" proprietary_codecs=true ffmpeg_branding=\"Chrome\" chrome_pgo_phase=0"
    [ ! -f out/linux/build.ninja ] && gn gen out/linux --args="$ARGS"
    ninja -C out/linux chrome chrome/installer/linux:stable_deb -j$NINJA_JOBS
    cp out/linux/chromium-browser-stable_*.deb /host_out/ 2>/dev/null || true
    do_release "deb"
fi

if [ "$BUILD_TARGET" = "win" ] || [ "$BUILD_TARGET" = "all" ]; then
    echo "🔨 Building Windows Installer..."
    mkdir -p out/win
    ARGS="is_official_build=true symbol_level=0 target_os=\"win\" proprietary_codecs=true ffmpeg_branding=\"Chrome\" chrome_pgo_phase=0"
    [ ! -f out/win/build.ninja ] && gn gen out/win --args="$ARGS"
    ninja -C out/win mini_installer -j$NINJA_JOBS
    cp out/win/mini_installer.exe /host_out/mini_installer-$CHROMIUM_VERSION.exe 2>/dev/null || true
    do_release "win"
fi

echo "$CHROMIUM_VERSION" > "$VOLUME_NAME/.last_built_version"
echo "✅ SUCCESS."
