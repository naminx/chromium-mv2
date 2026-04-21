#!/usr/bin/env bash
# build-docker.sh — The Chromium Build Engine (Proven Single Source)
#
# This script is a Two-Phase State Machine:
# PHASE 1: Host-Side Preparation (Sync, Toolchains, Memory Resilience)
# PHASE 2: Container-Side Compilation (Patches, GN, Ninja)
set -e

# --- Configuration ---
IMAGE_NAME="chromium-mv2-builder-v12"
VOLUME_NAME="${VOLUME_NAME:-chromium-mv2-src}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <VERSION> [--target <deb|win|all>] [--setup-only]"
    exit 1
}

if [ -z "$1" ] || [[ "$1" == -* ]]; then usage; fi
CHROMIUM_VERSION="$1"; BUILD_TARGET="all"; SETUP_ONLY="0"
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --target) BUILD_TARGET="$2"; shift 2 ;;
        --setup-only) SETUP_ONLY="1"; shift ;;
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
    fuse libfuse2 ciopfs unzip p7zip-full pkg-config binutils rpm dpkg-dev patch gperf git-restore-mtime \
    devscripts fakeroot && rm -rf /var/lib/apt/lists/*
APT
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
        if [ ! -d "src" ]; then 
            echo "🚀 Performing high-speed manual clone of src tag $CHROMIUM_VERSION..."
            git clone --depth 1 --branch "$CHROMIUM_VERSION" --progress https://chromium.googlesource.com/chromium/src.git
        else 
            echo "🚀 Performing high-speed manual fetch of src tag $CHROMIUM_VERSION..."
            git -C src fetch origin "refs/tags/$CHROMIUM_VERSION" --depth 1 --progress && git -C src checkout FETCH_HEAD
        fi

        echo "📥 Syncing dependencies (Universal)..."
        # EXACT FLAGS from backups/build-hetzner.sh
        gclient sync --nohooks --no-history --shallow --verbose -j$(nproc)
        
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

    # 1.4 Recurse into Docker
    echo "🚀 Launching build engine..."
    docker run --rm -i \
        --network host --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor:unconfined \
        -v "$(pwd):/chromium" \
        -v "${SCRIPT_DIR}/patches:/patches:ro" \
        -v "${SCRIPT_DIR}:/host_out" \
        $( [ -d "${SCRIPT_DIR}/out_ramdisk" ] && echo "-v ${SCRIPT_DIR}/out_ramdisk:/chromium/src/out" ) \
        -e "VOLUME_NAME=/chromium" \
        -e "VPYTHON_VENV_ROOT=/chromium/.cache/vpython" \
        -e "PIP_CACHE_DIR=/chromium/.cache/pip" \
        -e "HCLOUD_TOKEN=${HCLOUD_TOKEN}" \
        -e "GITHUB_TOKEN=${GITHUB_TOKEN}" \
        "$IMAGE_NAME" bash "/chromium/$(basename "$0")" "$CHROMIUM_VERSION" --target "$BUILD_TARGET"
    exit $?
fi

# ── PHASE 2: Compilation (Runs inside Container) ─────────────────────────────
set -e
cd "$VOLUME_NAME"
export PATH="/depot_tools:$PATH"
export GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1

# 2.1 CLEAN AND PATCH FIRST (WHY):
# We must perform 'git reset' before the toolchain 'sed' patches, otherwise
# git will see our technical overrides as "local changes" and wipe them.
cd src
echo "🧹 Cleaning and Patching..."
git reset --hard HEAD 2>/dev/null || true; git clean -fd 2>/dev/null || true
for p in /patches/*.patch; do 
    [ -f "$p" ] && echo "  🩹 Applying: $(basename "$p")" && patch -p1 --forward --batch < "$p" || true
done

# 2.2 Incremental Intelligence (WHY):
# Chromium builds take 6+ hours. By restoring timestamps for unchanged files
# (git diff | xargs touch), we tell Ninja to skip 99% of the work on minor upgrades.
VERSION_FILE="$VOLUME_NAME/.last_built_version"
PREV_VERSION=""
[ -f "$VERSION_FILE" ] && PREV_VERSION=$(cat "$VERSION_FILE")
if [ "$PREV_VERSION" != "$CHROMIUM_VERSION" ] && [ -n "$PREV_VERSION" ]; then
    echo "🔄 Version bump detected ($PREV_VERSION -> $CHROMIUM_VERSION)..."
    if git rev-parse "$PREV_VERSION" >/dev/null 2>&1; then
        echo "🕐 Restoring timestamps for incremental build speed..."
        git diff --name-only --diff-filter=d "$PREV_VERSION" "$CHROMIUM_VERSION" | xargs -r touch -c || true
    fi
fi

# 2.3 Windows Toolchain Configuration (PROVEN METHOD)
if [ "$BUILD_TARGET" = "win" ] || [ "$BUILD_TARGET" = "all" ]; then
    HASH="e66617bc68"; TOOLCHAIN_ROOT="$VOLUME_NAME/win_toolchain"; TOOLCHAIN_DEST="$TOOLCHAIN_ROOT/vs_files/$HASH"
    
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

    # 2.3.2 THE DOUBLE SPOOF (WHY):
    # Even with overrides, Chromium checks internal version strings. We use 'sed'
    # to "lie" to the build system so it accepts our custom toolchain as official.
    if [ -f build/vs_toolchain.py ]; then
        echo "🩹 Force-patching vs_toolchain.py (Sacred Sequence)..."
        sed -i "s/TOOLCHAIN_HASH = .*/TOOLCHAIN_HASH = '$HASH'/g" build/vs_toolchain.py
        sed -i "s/SDK_VERSION = .*/SDK_VERSION = '10.0.26100.0'/g" build/vs_toolchain.py
        sed -i "s/subprocess.check_call(get_toolchain_args)/pass/g" build/vs_toolchain.py
    fi
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
fi

if [ "$BUILD_TARGET" = "win" ] || [ "$BUILD_TARGET" = "all" ]; then
    echo "🔨 Building Windows Installer..."
    mkdir -p out/win
    ARGS="is_official_build=true symbol_level=0 target_os=\"win\" proprietary_codecs=true ffmpeg_branding=\"Chrome\" chrome_pgo_phase=0"
    [ ! -f out/win/build.ninja ] && gn gen out/win --args="$ARGS"
    ninja -C out/win mini_installer -j$NINJA_JOBS
    cp out/win/mini_installer.exe /host_out/mini_installer-$CHROMIUM_VERSION.exe 2>/dev/null || true
fi

echo "$CHROMIUM_VERSION" > "$VERSION_FILE"
echo "✅ SUCCESS."
