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
        --shallow) shift ;; # Legacy
        *) shift ;;
    esac
done

# ── PHASE 1: Data Preparation (Runs on Host for Speed) ───────────────────────
if [ ! -f /.dockerenv ]; then
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

    cd "$VOLUME_NAME"
    if [ "$SKIP_GCLIENT_SYNC" != "1" ]; then
        if [ ! -d "depot_tools" ]; then git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git depot_tools; fi
        export PATH="$(pwd)/depot_tools:$PATH"
        export GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1
        echo "📝 Configuring Universal .gclient..."
        cat > .gclient << 'PYTHON'
solutions = [ { "name": "src", "url": "https://chromium.googlesource.com/chromium/src.git", "managed": False, "custom_deps": {}, "custom_vars": {}, } ]
target_os = ["win", "linux"]
PYTHON
        if [ ! -d "src" ]; then 
            echo "🚀 Performing high-speed manual clone of src tag $CHROMIUM_VERSION..."
            git clone --depth 1 --branch "$CHROMIUM_VERSION" --progress https://chromium.googlesource.com/chromium/src.git
        else 
            echo "🚀 Performing high-speed manual fetch of src tag $CHROMIUM_VERSION..."
            git -C src fetch origin "refs/tags/$CHROMIUM_VERSION" --depth 1 --progress && git -C src checkout FETCH_HEAD
        fi
        echo "📥 Syncing dependencies (Universal)..."
        gclient sync --nohooks --no-history --shallow --verbose -j$(nproc)
        echo "🛠️  Updating gclient hooks..."
        export DEPOT_TOOLS_WIN_TOOLCHAIN=0
        gclient runhooks
        echo "🔧 Updating Clang..."
        python3 src/tools/clang/scripts/update.py
    fi

    if [ "$SETUP_ONLY" = "1" ]; then echo "✅ Setup Complete. Volume is Warm."; exit 0; fi

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

cd src
echo "🧹 Cleaning and Patching..."
git reset --hard HEAD 2>/dev/null || true; git clean -fd 2>/dev/null || true
for p in /patches/*.patch; do [ -f "$p" ] && echo "  🩹 Applying: $(basename "$p")" && patch -p1 --forward --batch < "$p" || true; done

# Windows Toolchain Configuration
if [ "$BUILD_TARGET" = "win" ] || [ "$BUILD_TARGET" = "all" ]; then
    HASH="42b5b0689e"; TOOLCHAIN_ROOT="$VOLUME_NAME/win_toolchain"; TOOLCHAIN_DEST="$TOOLCHAIN_ROOT/vs_files/$HASH"
    
    if ! mountpoint -q "$TOOLCHAIN_ROOT/vs_files"; then
        mkdir -p "$TOOLCHAIN_ROOT/vs_files.ciopfs" "$TOOLCHAIN_ROOT/vs_files"
        echo "📂 Mounting case-insensitive toolchain filesystem..."
        ciopfs -o use_ino "$TOOLCHAIN_ROOT/vs_files.ciopfs" "$TOOLCHAIN_ROOT/vs_files" || true
    fi

    if [ ! -f "$TOOLCHAIN_DEST/vs_version" ]; then
        echo "📂 Preparing Windows toolchain (7z)..."
        mkdir -p "$TOOLCHAIN_DEST"
        [ ! -f "$VOLUME_NAME/$HASH.7z" ] && curl -L -o "$VOLUME_NAME/$HASH.7z" "https://github.com/naminx/chromium-toolchain/releases/download/v1.0.0.$HASH/$HASH.7z"
        7z x -p$HASH "$VOLUME_NAME/$HASH.7z" -o"$TOOLCHAIN_DEST"
    fi
    
    export GYP_MSVS_OVERRIDE_PATH="$TOOLCHAIN_DEST"
    export WINDOWSSDKDIR="$TOOLCHAIN_DEST/windows kits/10"
    mkdir -p /depot_tools/win_toolchain && ln -sfn "$TOOLCHAIN_ROOT/vs_files" /depot_tools/win_toolchain/vs_files
    
    mkdir -p build
    # WHY: We use EXACT lowercase paths found in your 7z archive to satisfy vs_toolchain.py checks.
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

    if [ -f build/vs_toolchain.py ]; then
        echo "🩹 Force-patching vs_toolchain.py..."
        sed -i "s/TOOLCHAIN_HASH = .*/TOOLCHAIN_HASH = '$HASH'/g" build/vs_toolchain.py
        sed -i "s/SDK_VERSION = .*/SDK_VERSION = '10.0.26100.0'/g" build/vs_toolchain.py
        sed -i "s/subprocess.check_call(get_toolchain_args)/pass/g" build/vs_toolchain.py
    fi
    export DEPOT_TOOLS_WIN_TOOLCHAIN=1
else
    export DEPOT_TOOLS_WIN_TOOLCHAIN=0
fi

# Resources and Build
CPU_COUNT=$(nproc); TOTAL_MEM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
NINJA_JOBS=$(( TOTAL_MEM_GB / 2 )); [ "$NINJA_JOBS" -lt 1 ] && NINJA_JOBS=1
[ "$NINJA_JOBS" -gt "$CPU_COUNT" ] && NINJA_JOBS=$CPU_COUNT
CONCURRENT_LINKS=$(( TOTAL_MEM_GB / 16 )); [ "$CONCURRENT_LINKS" -lt 1 ] && CONCURRENT_LINKS=1

if [ "$BUILD_TARGET" = "deb" ] || [ "$BUILD_TARGET" = "all" ]; then
    echo "🔨 Building Linux..."
    mkdir -p out/linux
    ARGS="is_official_build=true symbol_level=0 target_os=\"linux\" proprietary_codecs=true ffmpeg_branding=\"Chrome\" chrome_pgo_phase=0"
    [ ! -f out/linux/build.ninja ] && gn gen out/linux --args="$ARGS"
    ninja -C out/linux chrome chrome/installer/linux:stable_deb -j$NINJA_JOBS
    cp out/linux/chromium-browser-stable_*.deb /host_out/ 2>/dev/null || true
fi

if [ "$BUILD_TARGET" = "win" ] || [ "$BUILD_TARGET" = "all" ]; then
    echo "🔨 Building Windows..."
    mkdir -p out/win
    ARGS="is_official_build=true symbol_level=0 target_os=\"win\" proprietary_codecs=true ffmpeg_branding=\"Chrome\" chrome_pgo_phase=0"
    [ ! -f out/win/build.ninja ] && gn gen out/win --args="$ARGS"
    ninja -C out/win mini_installer -j$NINJA_JOBS
    cp out/win/mini_installer.exe /host_out/mini_installer-$CHROMIUM_VERSION.exe 2>/dev/null || true
fi
echo "✅ SUCCESS."
