#!/usr/bin/env bash
# build-docker.sh — The Chromium Build Engine (Proven Single Source)
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

        # 1.4 PROVEN GARBAGE COLLECTION
        # WHY: 'rm -rf' on a failed 100GB sync takes forever. By renaming to .trash
        # and deleting in the background, we allow the next attempt to start 
        # IMMEDIATELY without wasting server time on large-scale deletions.
        echo "🧹 Sweeping corrupted component debris..."
        find . -maxdepth 3 -type d \( -name "_gclient_src_*" -o -name "_bad_scm" \) -print | while read d; do
            TRASH=".trash_$(date +%s)_$(basename "$d")"
            mv "$d" "$TRASH" 2>/dev/null || true
            nohup rm -rf "$TRASH" >/dev/null 2>&1 &
        done

        # 1.5 PROVEN HIGH-SPEED FETCH (Raw Git)
        # WHY: Raw git fetch with --progress talks directly to the terminal.
        # gclient sync is silent for 30GB, which looks like a stall in the cloud.
        if [ ! -d "src" ]; then 
            echo "🚀 Performing high-speed manual clone of src tag $CHROMIUM_VERSION..."
            git clone --depth 1 --branch "$CHROMIUM_VERSION" --progress https://chromium.googlesource.com/chromium/src.git
        else 
            echo "🚀 Performing high-speed manual fetch of src tag $CHROMIUM_VERSION..."
            git -C src fetch origin "refs/tags/$CHROMIUM_VERSION" --depth 1 --progress && git -C src checkout FETCH_HEAD
        fi

        echo "📥 Syncing dependencies (Universal)..."
        gclient sync --nohooks --no-history --shallow --verbose -j$(nproc)
        
        # 1.6 SAFE TOOLCHAIN SEQUENCE
        # WHY: We MUST disable Windows hooks during runhooks to prevent 401
        # Unauthorized errors from Google's private storage.
        echo "🛠️  Updating gclient hooks..."
        export DEPOT_TOOLS_WIN_TOOLCHAIN=0
        gclient runhooks
        echo "🔧 Updating Clang..."
        python3 src/tools/clang/scripts/update.py
    fi

    if [ "$SETUP_ONLY" = "1" ]; then echo "✅ Setup Complete."; exit 0; fi

    # 1.3 Recurse into Docker
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

# Target Tracking
LAST_TARGET_FILE="$VOLUME_NAME/.last_target"
[ -f "$LAST_TARGET_FILE" ] && LAST_TARGET=$(cat "$LAST_TARGET_FILE") || LAST_TARGET=""
if [ "$LAST_TARGET" != "$BUILD_TARGET" ] && [ "$LAST_TARGET" != "all" ]; then
    echo "$BUILD_TARGET" > "$LAST_TARGET_FILE"
fi

# 2.2 Incremental Intelligence
# WHY: On future minor upgrades (e.g. .101 -> .102), Ninja would normally 
# recompile everything because 'git checkout' touches every file's timestamp.
# We find only the files that ACTUALLY changed and 'touch' them, effectively
# telling Ninja that the other 30,000 files are still up-to-date.
cd src
VERSION_FILE="$VOLUME_NAME/.last_built_version"
PREV_VERSION=""
[ -f "$VERSION_FILE" ] && PREV_VERSION=$(cat "$VERSION_FILE")
if [ "$PREV_VERSION" != "$CHROMIUM_VERSION" ] && [ -n "$PREV_VERSION" ]; then
    echo "🔄 Version bump detected ($PREV_VERSION -> $CHROMIUM_VERSION)..."
    if git rev-parse "$PREV_VERSION" >/dev/null 2>&1; then
        echo "🕐 Restoring timestamps for incremental builds..."
        git diff --name-only --diff-filter=d "$PREV_VERSION" "$CHROMIUM_VERSION" | xargs -r touch -c || true
    fi
fi

# Windows Toolchain Configuration
if [ "$BUILD_TARGET" = "win" ] || [ "$BUILD_TARGET" = "all" ]; then
    HASH="42b5b0689e"; TOOLCHAIN_ROOT="$VOLUME_NAME/win_toolchain"; TOOLCHAIN_DEST="$TOOLCHAIN_ROOT/vs_files/$HASH"
    
    # ciopfs Mount (Case-insensitivity fix)
    # WHY: Windows headers (e.g. Windows.h) use MixedCase. Linux is case-sensitive. 
    # ciopfs emulates a case-insensitive disk so clang can find these headers 
    # during the cross-compile, preventing "file not found" errors.
    if ! mountpoint -q "$TOOLCHAIN_ROOT/vs_files"; then
        mkdir -p "$TOOLCHAIN_ROOT/vs_files.ciopfs" "$TOOLCHAIN_ROOT/vs_files"
        echo "📂 Mounting case-insensitive toolchain filesystem..."
        ciopfs -o use_ino "$TOOLCHAIN_ROOT/vs_files.ciopfs" "$TOOLCHAIN_ROOT/vs_files" || true
    fi
    if [ ! -f "$TOOLCHAIN_DEST/VS_VERSION" ]; then
        echo "📂 Extracting Windows toolchain (7z)..."
        mkdir -p "$TOOLCHAIN_DEST"
        7z x -p$HASH "$VOLUME_NAME/$HASH.7z" -o"$TOOLCHAIN_DEST"
    fi
    mkdir -p /depot_tools/win_toolchain && ln -sfn "$TOOLCHAIN_ROOT/vs_files" /depot_tools/win_toolchain/vs_files
    mkdir -p build && cat > build/win_toolchain.json << JSON
{"path": "/chromium/win_toolchain/vs_files/42b5b0689e", "version": "42b5b0689e", "win_sdk": "/chromium/win_toolchain/vs_files/42b5b0689e/Windows Kits/10", "wdk": "/chromium/win_toolchain/vs_files/42b5b0689e/wdk", "runtime_dirs": ["/chromium/win_toolchain/vs_files/42b5b0689e/sys64", "/chromium/win_toolchain/vs_files/42b5b0689e/sys32"]}
JSON
    export DEPOT_TOOLS_WIN_TOOLCHAIN=1
else
    export DEPOT_TOOLS_WIN_TOOLCHAIN=0
fi

# Cleanup and Patching
echo "🧹 Cleaning and Patching..."
git reset --hard HEAD 2>/dev/null || true; git clean -fd 2>/dev/null || true
for p in /patches/*.patch; do [ -f "$p" ] && echo "  🩹 Applying: $(basename "$p")" && patch -p1 --forward --batch < "$p" || true; done

# Ninja jobs
CPU_COUNT=$(nproc); TOTAL_MEM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
NINJA_JOBS=$(( TOTAL_MEM_GB / 2 )); [ "$NINJA_JOBS" -lt 1 ] && NINJA_JOBS=1
[ "$NINJA_JOBS" -gt "$CPU_COUNT" ] && NINJA_JOBS=$CPU_COUNT
CONCURRENT_LINKS=$(( TOTAL_MEM_GB / 16 )); [ "$CONCURRENT_LINKS" -lt 1 ] && CONCURRENT_LINKS=1

if [ "$BUILD_TARGET" = "deb" ] || [ "$BUILD_TARGET" = "all" ]; then
    echo "🔨 Building Linux..."
    mkdir -p out/linux
    ARGS="is_official_build=true symbol_level=0 target_os=\"linux\" proprietary_codecs=true ffmpeg_branding=\"Chrome\" concurrent_links=$CONCURRENT_LINKS"
    [ ! -f out/linux/args.gn ] && gn gen out/linux --args="$ARGS"
    ninja -C out/linux chrome chrome/installer/linux:stable_deb -j$NINJA_JOBS
    cp out/linux/chromium-browser-stable_*.deb /host_out/ 2>/dev/null || true
fi

if [ "$BUILD_TARGET" = "win" ] || [ "$BUILD_TARGET" = "all" ]; then
    echo "🔨 Building Windows..."
    mkdir -p out/win
    ARGS="is_official_build=true symbol_level=0 target_os=\"win\" proprietary_codecs=true ffmpeg_branding=\"Chrome\" concurrent_links=$CONCURRENT_LINKS"
    [ ! -f out/win/args.gn ] && gn gen out/win --args="$ARGS"
    ninja -C out/win mini_installer -j$NINJA_JOBS
    cp out/win/mini_installer.exe /host_out/mini_installer-$CHROMIUM_VERSION.exe 2>/dev/null || true
fi

echo "$CHROMIUM_VERSION" > "$VERSION_FILE"
echo "✅ SUCCESS."
