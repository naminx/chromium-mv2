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
IMAGE_NAME="chromium-mv2-builder-v6"
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
    fuse ciopfs unzip patch gperf git-restore-mtime \
    && rm -rf /var/lib/apt/lists/*

# depot_tools (contains gclient, fetch, gn)
RUN git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git /depot_tools
ENV PATH="/depot_tools:$PATH"

# Bootstrap depot_tools so that python3_bin_reldir.txt is created.
# Without this gn/gclient wrappers fail with "not initialized".
# DEPOT_TOOLS_UPDATE=0 is NOT set here so the bootstrap is allowed to run.
RUN DEPOT_TOOLS_METRICS=0 /depot_tools/update_depot_tools

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
    --device /dev/fuse \
    --cap-add SYS_ADMIN \
    --security-opt apparmor:unconfined \
    --ulimit nofile=65536:65536 \
    -v "${VOLUME_NAME}:/chromium" \
    -v "${PATCHES_DIR}:/patches:ro" \
    -v "${SCRIPT_DIR}/42b5b0689e.zip:/toolchain.zip:ro" \
    -v "${SCRIPT_DIR}:/host_out" \
    -e "CHROMIUM_VERSION=${CHROMIUM_VERSION}" \
    -e "PATH=/depot_tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e "DEPOT_TOOLS_UPDATE=0" \
    -e "DEPOT_TOOLS_METRICS=0" \
    -e "GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1" \
    "$IMAGE_NAME" bash << 'INNER'
set -e

# Chromium's parallel build + ciopfs FUSE easily exhaust the default fd limit.
# Raise it early before anything else runs.
ulimit -n 65536 2>/dev/null || true

echo "════════════════════════════════════════════════════"
echo " Target: Chromium $CHROMIUM_VERSION"
echo "════════════════════════════════════════════════════"

cd /chromium

# ── Windows Toolchain Setup ──────────────────────────────────────────────────
TOOLCHAIN_ROOT="/chromium/win_toolchain"
HASH="42b5b0689e"
TOOLCHAIN_DEST="$TOOLCHAIN_ROOT/vs_files/$HASH"

# 1. Mount ciopfs (required for case-insensitive headers on Linux)
mkdir -p "$TOOLCHAIN_ROOT/vs_files.ciopfs" "$TOOLCHAIN_ROOT/vs_files"
if ! mountpoint -q "$TOOLCHAIN_ROOT/vs_files"; then
    echo "📂 Mounting case-insensitive toolchain filesystem..."
    ciopfs -o use_ino "$TOOLCHAIN_ROOT/vs_files.ciopfs" "$TOOLCHAIN_ROOT/vs_files" || true
fi

# 2. Extract toolchain if missing (Perform only once)
if [ ! -f "$TOOLCHAIN_DEST/VS_VERSION" ]; then
    echo "📦 Initializing Windows toolchain in volume..."
    mkdir -p "$TOOLCHAIN_DEST"
    if [ -f "/toolchain.zip" ]; then
        echo "📂 Extracting toolchain (this may take a minute)..."
        unzip -q /toolchain.zip -d "$TOOLCHAIN_DEST"
        echo "✅ Extraction complete."
    else
        echo "⚠️  Warning: /toolchain.zip not found. Build may fail if toolchain is missing."
    fi
fi

# Link to depot_tools so the build scripts find it naturally
mkdir -p /depot_tools/win_toolchain
ln -sfn "$TOOLCHAIN_ROOT/vs_files" /depot_tools/win_toolchain/vs_files

# DEPOT_TOOLS_WIN_TOOLCHAIN stays at default (1) so GetVisualStudioVersion()
# returns '2022' without trying to auto-detect VS on Linux.
# The win_toolchain.json we write below makes ShouldUpdateToolchain() return
# False, which prevents any download attempt.

# ── First-time source fetch ───────────────────────────────────────────────────
# Clean up orphaned gclient temp directories BEFORE attempting any fetch/sync.
# When 'fetch' or 'gclient sync' is interrupted mid-clone (e.g. disk full,
# Ctrl+C, OOM-kill), it leaves behind:
#   _gclient_src_XXXXXXXX/  — partial git clone, can be gigabytes
#   _bad_scm/               — gclient's own failed-recovery debris
# These silently fill the disk so every subsequent retry hits the same
# "No space left on device" error and the volume never recovers.
echo "🧹 Cleaning up any orphaned gclient temp directories..."
FOUND_TEMP=0
for d in _gclient_src_* _bad_scm; do
    if [ -d "$d" ]; then
        echo "   🗑️  Removing leftover: $d"
        rm -rf "$d"
        FOUND_TEMP=1
    fi
done
[ "$FOUND_TEMP" -eq 0 ] && echo "   ✅ None found."

# ── First-time source fetch ───────────────────────────────────────────────────
# We write .gclient manually (same content as 'fetch --nohooks chromium' would
# produce) and then call gclient sync directly. This lets us wrap the 30 GB
# clone in a retry loop — 'fetch' has no built-in retry for fatal clone errors
# like "invalid index-pack output" (transient network failures during large
# pack transfers).
if [ ! -f ".gclient" ]; then
    echo ""
    echo "📝 Writing .gclient config (equivalent to 'fetch --nohooks chromium')..."
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
GCLIENTEOF
fi

# Clone/sync with retry.  The Chromium source is ~30 GB and a single dropped
# TCP packet causes git to abort with "invalid index-pack output".  We clean
# up gclient's temp dirs before each attempt so it always starts fresh.
if [ ! -d "src" ] || ! git -C src rev-parse --git-dir > /dev/null 2>&1; then
    [ -d "src" ] && echo "🗑️  Removing broken partial src/ checkout..." && rm -rf src
    for attempt in 1 2 3; do
        echo ""
        echo "📥 Fetching Chromium source tree (~30 GB) — attempt ${attempt}/3..."
        # Clean temp dirs from any previous failed attempt before retrying.
        for d in _gclient_src_* _bad_scm; do
            [ -d "$d" ] && echo "   🗑️  Cleaning leftover: $d" && rm -rf "$d"
        done
        if gclient sync --nohooks --with_branch_heads --with_tags; then
            echo "✅ Source fetch complete."
            break
        fi
        if [ "$attempt" -lt 3 ]; then
            echo "⚠️  Fetch failed (attempt ${attempt}/3) — likely a transient network error."
            echo "   Waiting 60s before retry..."
            sleep 60
        else
            echo "❌ Source fetch failed after 3 attempts. Check network connectivity."
            exit 1
        fi
    done
fi

cd src

# ── Write win_toolchain.json (must exist BEFORE gclient runhooks) ─────────────
# vs_toolchain.py checks for this file. If it matches version '2022',
# ShouldUpdateToolchain() returns False → no download is attempted.
# Written as a function so we can call it again after gclient sync (which may
# recreate the build/ directory or clobber the file).
write_toolchain_json() {
    mkdir -p build
    # Generate desired content first, then only overwrite if it changed.
    # Avoiding mtime bumps prevents GN from treating the toolchain as modified.
    NEW=$(cat <<'TCEOF'
{
  "path": "TOOLCHAIN_DEST_PLACEHOLDER",
  "version": "2022",
  "win_sdk": "TOOLCHAIN_DEST_PLACEHOLDER/Windows Kits/10",
  "wdk": "TOOLCHAIN_DEST_PLACEHOLDER/wdk",
  "runtime_dirs": [
    "TOOLCHAIN_DEST_PLACEHOLDER/sys64",
    "TOOLCHAIN_DEST_PLACEHOLDER/sys32",
    "TOOLCHAIN_DEST_PLACEHOLDER/sysarm64"
  ]
}
TCEOF
)
    NEW=$(echo "$NEW" | sed "s|TOOLCHAIN_DEST_PLACEHOLDER|$TOOLCHAIN_DEST|g")
    EXISTING=$(cat build/win_toolchain.json 2>/dev/null || true)
    if [ "$NEW" != "$EXISTING" ]; then
        echo "$NEW" > build/win_toolchain.json
        echo "✅ win_toolchain.json updated."
    else
        echo "✅ win_toolchain.json unchanged (skipping write)."
    fi
}

export GYP_MSVS_OVERRIDE_PATH="$TOOLCHAIN_DEST"
export WINDOWSSDKDIR="$TOOLCHAIN_DEST/Windows Kits/10"
# Keep =0 initially so 'gclient runhooks → vs_toolchain.py update --force' skips
# the GCS download. DEPOT_TOOLS_WIN_TOOLCHAIN=0 makes Update() return 0
# immediately without calling get_toolchain_if_necessary.py. We'll flip to 1
# before gn gen so GetVisualStudioVersion() returns '2022'.
export DEPOT_TOOLS_WIN_TOOLCHAIN=0

# First call – build/ may not exist yet if repo was just fetched,
# but we try anyway; it will succeed once src/ exists.
[ -d build ] && write_toolchain_json || true

# Revert any previously applied patches so git checkout can proceed cleanly.
# Patches are re-applied from /patches on every run, so this is always safe.
# (git clean -fd is intentionally omitted: out/ is gitignored and must be kept
#  for incremental builds; our patches only modify tracked files anyway.)
git reset --hard HEAD 2>/dev/null || true

# VERSION_FILE must be defined HERE — before PREV_VERSION is read — so the
# incremental "touch changed files" step below actually fires.
# (Previously this was defined ~120 lines later, making PREV_VERSION always
# empty and causing ninja to silently use stale artifacts after version bumps.)
VERSION_FILE="out/win/.last_built_version"
PREV_VERSION=""
[ -f "$VERSION_FILE" ] && PREV_VERSION=$(cat "$VERSION_FILE")

if ! git rev-parse "$CHROMIUM_VERSION" >/dev/null 2>&1 || [ "$(git rev-parse HEAD)" != "$(git rev-parse "${CHROMIUM_VERSION}^{commit}" 2>/dev/null)" ]; then
    echo "🔄 Syncing to version $CHROMIUM_VERSION..."
    git fetch --tags
    git checkout "$CHROMIUM_VERSION"
    # git checkout stamps every touched file with "now", which makes ninja
    # think the entire source tree is modified → full recompile.
    #
    # Fix in two steps:
    # 1. git-restore-mtime: resets each file's mtime to the last commit that
    #    modified it (historical, old timestamps → ninja skips unchanged files).
    # 2. Touch files that actually changed vs the previous version: their
    #    historical commit timestamps are older than when we built the previous
    #    version, so without this touch ninja would incorrectly skip them.
    echo "🕐 Restoring source file timestamps (git restore-mtime)..."
    git restore-mtime --force
    if [ -n "$PREV_VERSION" ] && git rev-parse "$PREV_VERSION" >/dev/null 2>&1; then
        echo "🔁 Touching files changed between $PREV_VERSION and $CHROMIUM_VERSION..."
        git diff --name-only "$PREV_VERSION" "$CHROMIUM_VERSION" | xargs -d '\n' touch --
    fi
else
    echo "✅ Already at version $CHROMIUM_VERSION. Skipping fetch/checkout."
fi

# Ensure .gclient declares target_os = ['win'] for the Windows cross-toolchain
if ! grep -q "target_os" /chromium/.gclient 2>/dev/null; then
    echo "target_os = ['win']" >> /chromium/.gclient
    echo "✅ Added target_os = ['win'] to .gclient"
fi

# gclient sync fetches third-party deps for this exact version.
# --force is intentionally OMITTED: it does 'git reset --hard' on all sub-repos,
# touching thousands of source file timestamps and causing a full recompile.
gclient sync \
    --nohooks \
    --with_branch_heads \
    --with_tags \
    --delete_unversioned_trees

echo "✅ Source synced to $CHROMIUM_VERSION"

# Re-write toolchain JSON after sync (sync may recreate build/ directory)
write_toolchain_json

# ── Install / update Linux host build dependencies ───────────────────────────
# These are the *host* tools needed to run the cross-compiler itself.
# IMPORTANT: sentinel is on the PERSISTENT VOLUME (/chromium), not /tmp.
# /tmp is a tmpfs cleared on every host reboot; using it caused gclient runhooks
# to re-fire after reboot, touching timestamps and triggering a full recompile.
if [ ! -f /chromium/.deps_installed ]; then
    echo ""
    echo "📦 Installing Linux host build dependencies (first run only)..."
    ./build/install-build-deps.sh --no-prompt --no-chromeos-fonts --no-arm
    touch /chromium/.deps_installed
    # Hooks set up the Windows cross-toolchain (clang, lld, rc.exe etc.).
    # DEPOT_TOOLS_WIN_TOOLCHAIN=0: makes 'vs_toolchain.py update --force' return
    # 0 without touching GCS. All other hooks (clang, etc.) are unaffected.
    gclient runhooks
fi

# Switch to =1 now: gn gen calls 'vs_toolchain.py get_toolchain_dir' which
# needs GetVisualStudioVersion() to return '2022'. With json in place and
# version matching, ShouldUpdateToolchain() returns False → no download.
export DEPOT_TOOLS_WIN_TOOLCHAIN=1
# Ensure JSON is still current (runhooks may have clobbered it)
write_toolchain_json

# ── Apply custom patches ──────────────────────────────────────────────────────
# git reset --hard above already cleaned the tree, so we don't need to revert.
# --input=FILE: read patch from file, not stdin (prevents patch from consuming
#   heredoc content when it wants to ask an interactive question)
# --forward: silently skip hunks that are already applied upstream (Chromium
#   may have adopted the change between minor versions)
# --batch: non-interactive; choose safe defaults for all prompts
echo ""
echo "🩹 Applying patches..."
PATCH_FAILED=0
for patch in /patches/*.patch; do
    patch_name="$(basename "$patch")"
    echo "  ✅ Applying: $patch_name"
    if ! patch -p1 --forward --batch --input="$patch"; then
        echo "  ❌ Patch failed: $patch_name — stopping build."
        PATCH_FAILED=1
    fi
done
if [ "$PATCH_FAILED" = "1" ]; then
    echo ""
    echo "❌ One or more patches failed. Check .rej files in the source tree."
    echo "   Update the failing patch before retrying the build."
    exit 1
fi

# ── Generate / refresh build configuration (Windows cross-compile) ───────────
echo ""
echo "⚙️  Configuring Windows cross-compile build (gn gen)..."

GN_ARGS='
    target_os = "win"
    is_debug = false
    is_official_build = true
    chrome_pgo_phase = 0
    symbol_level = 0
    blink_symbol_level = 0
    v8_symbol_level = 0
    enable_nacl = false
    proprietary_codecs = true
    ffmpeg_branding = "Chrome"
'
# Always run gn gen — it is idempotent and takes ~5s. The previous conditional
# used a fragile whitespace comparison that always triggered a re-run anyway,
# and the re-run could confuse ninja's dependency tracking.
echo "⚙️  Configuring build (gn gen)..."
gn gen out/win --args="$GN_ARGS"

# If the version changed, delete mini_installer.exe to force a relink.
# (An OOM-killed mid-build leaves the previous version's .exe which ninja
# otherwise considers up-to-date and never retouches.)
# PREV_VERSION was read near the top of this script now that VERSION_FILE
# is defined early — no need to re-read it here.
if [ -n "$PREV_VERSION" ] && [ "$PREV_VERSION" != "$CHROMIUM_VERSION" ]; then
    echo "Version changed ($PREV_VERSION → $CHROMIUM_VERSION) — forcing relink."
    rm -f out/win/mini_installer.exe out/win/mini_installer.exe.pdb
fi
echo "$CHROMIUM_VERSION" > "$VERSION_FILE"

CPU_COUNT=$(nproc)

# clang-cl Windows cross-compile uses ~2 GB RAM per parallel job.
# Cap job count so we don't OOM-kill workers silently on home PCs.
TOTAL_MEM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
MAX_JOBS_BY_MEM=$(( TOTAL_MEM_GB / 2 ))
[ "$MAX_JOBS_BY_MEM" -lt 1 ] && MAX_JOBS_BY_MEM=1
NINJA_JOBS=$(( CPU_COUNT < MAX_JOBS_BY_MEM ? CPU_COUNT : MAX_JOBS_BY_MEM ))
echo "   CPUs: $CPU_COUNT  |  RAM: ${TOTAL_MEM_GB}GB  |  ninja -j${NINJA_JOBS}"

echo ""
echo "Building mini_installer.exe (incremental)..."

# Use the explicit filename target so ninja is forced to rebuild the real file,
# not satisfy a phony alias that might incorrectly report 'up to date'.
ninja -C out/win mini_installer.exe -j${NINJA_JOBS}

if [ ! -f out/win/mini_installer.exe ]; then
    echo "❌ ERROR: ninja succeeded but mini_installer.exe was not produced!"
    echo "   This usually means the target was already considered up-to-date."
    echo "   Try running: docker run --rm -v chromium-mv2-src:/c ubuntu:22.04 rm /c/src/out/win/mini_installer.exe"
    exit 1
fi

DEST="/host_out/mini_installer-${CHROMIUM_VERSION}.exe"
cp out/win/mini_installer.exe "$DEST"

echo ""
echo "════════════════════════════════════════════════════"
echo " ✅ SUCCESS!"
echo "    mini_installer-${CHROMIUM_VERSION}.exe"
echo "    has been copied to your build-docker.sh directory."
echo "════════════════════════════════════════════════════"
INNER
