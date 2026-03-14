#!/usr/bin/env bash
# build-docker.sh — Cross-compile Chromium for Windows using Docker/Podman.
#
# Usage:
#   ./build-docker.sh <CHROMIUM_VERSION>
#   ./build-docker.sh 145.0.7632.116
#
# Produces: mini_installer.exe (Windows x64 installer)
#
# On the first run, this fetches the full Chromium source (~30 GB) and builds
# from scratch. Subsequent runs only recompile changed files (minutes, not hours).
#
# The source tree and build artefacts are stored in a named Docker volume
# (chromium-mv2-src) that persists between script invocations.

set -e

CHROMIUM_VERSION="${1:?Usage: $0 <CHROMIUM_VERSION>  e.g. 145.0.7632.116}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"
IMAGE_NAME="chromium-mv2-builder"
VOLUME_NAME="chromium-mv2-src"

# Prefer docker (already installed); fall back to podman.
if command -v docker &>/dev/null; then
    DOCKER=docker
    echo "🐳 Using Docker"
elif command -v podman &>/dev/null; then
    DOCKER=podman
    echo "🐳 Using Podman (rootless)"
else
    echo "❌ Neither docker nor podman found. Install one and retry."
    exit 1
fi

# ── Build the base image (cached after first run) ────────────────────────────
echo "📦 Ensuring base image '$IMAGE_NAME' exists..."
if ! $DOCKER image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "🔨 Building base image (first time only — installs Chromium build deps)..."
    $DOCKER build --tag "$IMAGE_NAME" - << 'DOCKERFILE'
FROM docker.io/library/ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
LABEL description="Chromium incremental build environment"

# Core tools first (small layer)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl wget sudo lsb-release file ca-certificates \
    python3 python-is-python3 python3-httplib2 \
    && rm -rf /var/lib/apt/lists/*

# depot_tools (contains gclient, fetch, gn)
RUN git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git /depot_tools
ENV PATH="/depot_tools:$PATH"

# Tell gclient not to prompt, and disable auto-update of depot_tools inside CI
ENV DEPOT_TOOLS_UPDATE=0
ENV DEPOT_TOOLS_METRICS=0

WORKDIR /chromium
DOCKERFILE
    echo "✅ Base image built!"
else
    echo "✅ Base image already exists. Skipping build."
fi

# ── Ensure the source volume exists ──────────────────────────────────────────
$DOCKER volume create "$VOLUME_NAME" > /dev/null 2>&1 || true

# ── Run the incremental build inside the container ───────────────────────────
echo ""
echo "🚀 Launching build container for Chromium $CHROMIUM_VERSION..."
echo "   Source volume : $VOLUME_NAME (persistent)"
echo "   Patches dir   : $PATCHES_DIR"
echo ""

$DOCKER run --rm -i \
    --name "chromium-mv2-build-$(date +%s)" \
    -v "${VOLUME_NAME}:/chromium" \
    -v "${PATCHES_DIR}:/patches:ro" \
    -e "CHROMIUM_VERSION=${CHROMIUM_VERSION}" \
    -e "PATH=/depot_tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e "DEPOT_TOOLS_UPDATE=0" \
    -e "DEPOT_TOOLS_METRICS=0" \
    "$IMAGE_NAME" bash << 'INNER'
set -e

echo "════════════════════════════════════════════════════"
echo " Target: Chromium $CHROMIUM_VERSION"
echo "════════════════════════════════════════════════════"

cd /chromium

# ── First-time source fetch ───────────────────────────────────────────────────
if [ ! -f ".gclient" ]; then
    echo ""
    echo "📥 First run: fetching Chromium source tree (~30 GB). Grab a coffee..."
    fetch --nohooks chromium
fi

# If fetch was interrupted so early that 'src/' wasn't even created,
# running a baseline gclient sync will clone it.
if [ ! -d "src" ]; then
    echo "🔄 Recovering partial checkout..."
    gclient sync --nohooks
fi

cd src

# Stash any previously applied patches before checkout so git checkout is clean
echo ""
echo "🔄 Syncing to version $CHROMIUM_VERSION..."
git fetch --tags --quiet
git checkout "$CHROMIUM_VERSION" --quiet

# Ensure .gclient declares target_os = ['win'] for the Windows cross-toolchain
if ! grep -q "target_os" /chromium/.gclient 2>/dev/null; then
    echo "target_os = ['win']" >> /chromium/.gclient
    echo "✅ Added target_os = ['win'] to .gclient"
fi

# gclient sync fetches Windows SDK + all third-party deps for this exact version
gclient sync \
    --nohooks \
    --with_branch_heads \
    --with_tags \
    --delete_unversioned_trees \
    --force \
    --quiet

echo "✅ Source synced to $CHROMIUM_VERSION"

# ── Install / update Linux host build dependencies ───────────────────────────
# These are the *host* tools needed to run the cross-compiler itself.
if [ ! -f /tmp/.deps_installed ]; then
    echo ""
    echo "📦 Installing Linux host build dependencies (first run only)..."
    ./build/install-build-deps.sh --no-prompt --no-chromeos-fonts --no-arm
    touch /tmp/.deps_installed
    # Hooks set up the Windows cross-toolchain (clang, lld, rc.exe etc.)
    gclient runhooks --quiet
fi

# ── Apply custom patches ──────────────────────────────────────────────────────
echo ""
echo "🩹 Applying patches..."
for patch in /patches/*.patch; do
    patch_name="$(basename "$patch")"
    # Soft-revert in case it was applied by a previous run of this script
    if patch -p1 -R --dry-run --quiet < "$patch" 2>/dev/null; then
        echo "  ↩️  Reverting (already applied): $patch_name"
        patch -p1 -R --quiet < "$patch"
    fi
    echo "  ✅ Applying: $patch_name"
    patch -p1 < "$patch"
done

# ── Generate / refresh build configuration (Windows cross-compile) ───────────
echo ""
echo "⚙️  Configuring Windows cross-compile build (gn gen)..."
GN_ARGS='
    target_os = "win"
    is_debug = false
    is_official_build = true
    symbol_level = 0
    blink_symbol_level = 0
    v8_symbol_level = 0
    enable_nacl = false
    proprietary_codecs = true
    ffmpeg_branding = "Chrome"
'
gn gen out/win --args="$GN_ARGS"

# ── Incremental compile ───────────────────────────────────────────────────────
echo ""
echo "🏗️  Building mini_installer.exe (incremental — only changed files will recompile)..."
CPU_COUNT=$(nproc)
ninja -C out/win mini_installer -j${CPU_COUNT}

echo ""
echo "════════════════════════════════════════════════════"
echo " ✅ SUCCESS! Windows installer is at:"
echo "    (inside volume) /chromium/src/out/win/mini_installer.exe"
echo ""
echo " To copy it to your current directory, run:"
echo "   docker run --rm \\"
echo "     -v chromium-mv2-src:/chromium \\"
echo "     -v \$(pwd):/out \\"
echo "     docker.io/library/ubuntu:22.04 \\"
echo '     cp /chromium/src/out/win/mini_installer.exe /out/'
echo "════════════════════════════════════════════════════"
INNER
