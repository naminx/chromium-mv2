#!/usr/bin/env bash
# build-docker.sh — Incrementally build Chromium using Docker/Podman.
#
# Usage:
#   ./build-docker.sh <CHROMIUM_VERSION>
#   ./build-docker.sh 145.0.7632.116
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

# Prefer podman for rootless operation; fall back to docker.
if command -v podman &>/dev/null; then
    DOCKER=podman
    echo "🐳 Using Podman (rootless)"
else
    DOCKER=docker
    echo "🐳 Using Docker"
fi

# ── Build the base image (cached after first run) ────────────────────────────
echo "📦 Ensuring base image '$IMAGE_NAME' exists..."
if ! $DOCKER image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "🔨 Building base image (first time only — installs Chromium build deps)..."
    $DOCKER build --tag "$IMAGE_NAME" - << 'DOCKERFILE'
FROM ubuntu:22.04
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

$DOCKER run --rm -it \
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
if [ ! -d "src" ]; then
    echo ""
    echo "📥 First run: fetching Chromium source tree (~30 GB). Grab a coffee..."
    fetch --nohooks chromium
fi

cd src

# Stash any previously applied patches before checkout so git checkout is clean
echo ""
echo "🔄 Syncing to version $CHROMIUM_VERSION..."
git fetch --tags --quiet
git checkout "$CHROMIUM_VERSION" --quiet

# gclient sync brings in all third-party deps for this exact version
gclient sync \
    --nohooks \
    --with_branch_heads \
    --with_tags \
    --delete_unversioned_trees \
    --force \
    --quiet

echo "✅ Source synced to $CHROMIUM_VERSION"

# ── Install / update build dependencies via the official helper ───────────────
# This is idempotent; it only installs missing packages.
if [ ! -f /tmp/.deps_installed ]; then
    echo ""
    echo "📦 Installing build dependencies (first run only)..."
    ./build/install-build-deps.sh --no-prompt --no-chromeos-fonts
    touch /tmp/.deps_installed
    # Hooks need running after dep install
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

# ── Generate / refresh build configuration ───────────────────────────────────
echo ""
echo "⚙️  Configuring build (gn gen)..."
GN_ARGS='
    is_debug = false
    is_official_build = true
    symbol_level = 0
    blink_symbol_level = 0
    v8_symbol_level = 0
    enable_nacl = false
    proprietary_codecs = true
    ffmpeg_branding = "Chrome"
'
gn gen out/Release --args="$GN_ARGS"

# ── Incremental compile ───────────────────────────────────────────────────────
echo ""
echo "🏗️  Building (incremental — only changed files will recompile)..."
CPU_COUNT=$(nproc)
ninja -C out/Release chrome -j${CPU_COUNT}

echo ""
echo "════════════════════════════════════════════════════"
echo " ✅ SUCCESS! Chrome binary is at:"
echo "    (inside volume) /chromium/src/out/Release/chrome"
echo ""
echo " To copy it out of the volume, run:"
echo "   docker run --rm -v ${VOLUME_NAME}:/chromium -v \$(pwd):/out ubuntu:22.04 \\"
echo '     cp /chromium/src/out/Release/chrome /out/'
echo "════════════════════════════════════════════════════"
INNER
