#!/usr/bin/env bash
# build-engine.sh — The Deterministic Chromium Build State Machine
# Paradigm: Stateful Build on Ephemeral Compute (Docker Edition)
set -euo pipefail

# =============================================================================
# 1. GLOBAL TELEMETRY & LOGGING
# =============================================================================
export TZ="Asia/Bangkok"
readonly START_TIME_STR=$(date +%Y%m%d-%H%M%S)
readonly PROJECT_ROOT="/chromium"
readonly LOG_DIR="${PROJECT_ROOT}/logs"

# 🪄 1. Prepare variables and create directories before opening the pipe
readonly LOG_FILE="${LOG_DIR}/build-${START_TIME_STR}.log"
mkdir -p "$LOG_DIR"

# 🪄 2. Bypass logging pipe using 'ts' from moreutils (more stable than awk)
# We use &> to capture both Stdout and Stderr in a single command
exec &> >(ts '[%Y-%m-%d %H:%M:%S]' | tee -a "$LOG_FILE")

log_info() { echo -e "[\e[32mINFO\e[0m] $1"; }
log_warn() { echo -e "[\e[33mWARN\e[0m] $1"; }
log_err()  { echo -e "[\e[31mERROR\e[0m] $1" >&2; exit 1; }

log_info "🚀 Manie Chromium Station Started. Log: $LOG_FILE"

# =============================================================================
# 2. CONFIGURATION
# =============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC_DIR="${PROJECT_ROOT}/src"
readonly STATE_DIR="${PROJECT_ROOT}/.build_state"
readonly PATCHES_DIR="${PROJECT_ROOT}/patches"

TARGET="all"
VERSION=""
IS_CHEAP_NODE=0
SYNC_ONLY=0

usage() {
    echo "Usage: $0 <VERSION> [--target deb|win|all] [--cheap] [--sync-only]"
    exit 1
}

[[ $# -lt 1 || "$1" == -* ]] && usage
readonly VERSION="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --cheap)  IS_CHEAP_NODE=1; shift ;;
        --sync-only) SYNC_ONLY=1; shift ;;
        *) shift ;;
    esac
done

# Axiom: Idempotent File Write
write_if_changed() {
    local readonly target_file="$1"
    local readonly temp_file="${target_file}.tmp"
    cat > "$temp_file"
    if [[ ! -f "$target_file" ]] || ! cmp -s "$temp_file" "$target_file" 2>/dev/null; then
        mkdir -p "$(dirname "$target_file")"
        mv "$temp_file" "$target_file"
        log_info "🗃️ State mutated: $target_file"
    else
        rm -f "$temp_file"
    fi
}

# =============================================================================
# 3. PHASE 1: ENVIRONMENT SETUP
# =============================================================================
log_info "📦 Phase 1: Environment Initialization..."
mkdir -p "$STATE_DIR/patches" "$SRC_DIR"

# 🪄 Fix: Trust the mounted volume to avoid "dubious ownership" errors
git config --global --add safe.directory '*'

# 🪄 The State Machine for depot_tools
readonly DEPOT_STATE_FILE="${STATE_DIR}/depot_tools_version"
local_depot_version=""
[[ -f "$DEPOT_STATE_FILE" ]] && local_depot_version=$(cat "$DEPOT_STATE_FILE")

# 🪄 Fix: Also check if depot_tools is actually bootstrapped in the CURRENT container
# (e.g. check for python3_bin_reldir.txt which is created after bootstrap)
if [[ "$local_depot_version" != "$VERSION" ]] || [[ ! -f "/depot_tools/python3_bin_reldir.txt" ]]; then
    log_info "📦 Bootstrapping depot_tools for version $VERSION (This takes ~1 min)..."
    export DEPOT_TOOLS_UPDATE=1
    gclient --version > /dev/null 2>&1
    export DEPOT_TOOLS_UPDATE=0

    # Save state after completion
    echo "$VERSION" > "$DEPOT_STATE_FILE"
else
    log_info "⏭️ depot_tools already bootstrapped for $VERSION. Skipping."
    export DEPOT_TOOLS_UPDATE=0
fi

cd "$PROJECT_ROOT"

# Ensure .gclient map exists
cat << 'PYTHON' | write_if_changed "${PROJECT_ROOT}/.gclient"
solutions = [ { "name": "src", "url": "https://chromium.googlesource.com/chromium/src.git", "managed": False, "custom_deps": {}, "custom_vars": {}, } ]
target_os = ["win", "linux"]
PYTHON

# =============================================================================
# 4. PHASE 2: ATOMIC SOURCE & PATCHING
# =============================================================================
log_info "🔄 Phase 2: Source & Patch Management..."
readonly VERSION_STATE_FILE="${STATE_DIR}/last_version"
local_last_version=""
[[ -f "$VERSION_STATE_FILE" ]] && local_last_version=$(cat "$VERSION_STATE_FILE")

if [[ ! -d "src/.git" ]]; then
    log_info "🚀 Initial shallow clone for ${VERSION}..."
    git clone --progress --depth 1 --branch "$VERSION" https://chromium.googlesource.com/chromium/src.git src
    echo "$VERSION" > "$VERSION_STATE_FILE"
elif [[ "$local_last_version" != "$VERSION" ]]; then
    log_info "♻️ Version mismatch. Performing safe incremental update..."
    cd "$SRC_DIR"
    # 1. Clean all state patches — source will be reset by checkout below
    rm -f "${STATE_DIR}/patches"/*.patch 2>/dev/null || true

    # 2. Fetch new version
    git fetch --progress origin "refs/tags/${VERSION}" --depth 1

    # 3. 🪄 The MTime Preserver: update files without affecting timestamps of unchanged files
    git checkout -f FETCH_HEAD

    echo "$VERSION" > "$VERSION_STATE_FILE"
    cd "$PROJECT_ROOT"
fi

# Apply/Update Patches
cd "$SRC_DIR"

# 🪄 0. Realize google-sync.patch with API keys baked in.
#     The template (google-sync.patch.in) has CUSTOM_GOOGLE_*_PLACEHOLDER strings;
#     Step 0 substitutes them and writes the realized patch to google-sync.patch.
#     The main loop then handles apply/skip via hash comparison — if keys haven't
#     changed the hash matches and nothing happens (no mtime change on source).
GOOGLE_SYNC_IN="${PATCHES_DIR}/google-sync.patch.in"
GOOGLE_SYNC_OUT="${PATCHES_DIR}/google-sync.patch"
if [[ -f "$GOOGLE_SYNC_IN" ]]; then
    missing_vars=""
    for var in CHROMIUM_MV2_API_KEY CHROMIUM_MV2_CLIENT_ID CHROMIUM_MV2_CLIENT_SECRET; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars="$missing_vars $var"
        fi
    done
    [[ -n "$missing_vars" ]] && log_err "❌ Required environment variables not set:$missing_vars"

    sed -e "s/CUSTOM_GOOGLE_API_KEY_PLACEHOLDER/$CHROMIUM_MV2_API_KEY/g" \
        -e "s/CUSTOM_GOOGLE_CLIENT_ID_PLACEHOLDER/$CHROMIUM_MV2_CLIENT_ID/g" \
        -e "s/CUSTOM_GOOGLE_CLIENT_SECRET_PLACEHOLDER/$CHROMIUM_MV2_CLIENT_SECRET/g" \
        "$GOOGLE_SYNC_IN" > "$GOOGLE_SYNC_OUT" || log_err "💥 Failed to substitute keys in google-sync.patch"
fi

# 🪄 1. The Patch Garbage Collector: revert patches that have been deleted
for state_p in "${STATE_DIR}/patches"/*.patch; do
    [[ -f "$state_p" ]] || continue
    p_name=$(basename "$state_p")
    if [[ ! -f "${PATCHES_DIR}/${p_name}" ]] && [[ ! -f "${PATCHES_DIR}/${p_name}.in" ]]; then
        log_info "🗑️ Patch deleted by user: $p_name. Reversing from source..."
        git restore $(git apply --numstat "$state_p" 2>/dev/null | awk '{print $3}') 2>/dev/null || true
        rm -f "$state_p"
    fi
done

# 🪄 2. Original logic: detect new / changed patches
for patch_file in "${PATCHES_DIR}"/*.patch; do
    [[ -f "$patch_file" ]] || continue
    p_name=$(basename "$patch_file")
    state_p="${STATE_DIR}/patches/${p_name}"

    curr_h=$(md5sum "$patch_file" | awk '{print $1}')
    old_h=""
    [[ -f "$state_p" ]] && old_h=$(md5sum "$state_p" | awk '{print $1}')

    if [[ "$curr_h" != "$old_h" ]]; then
        log_info "🩹 Patch changed: $p_name. Updating..."
        # Restore all files touched by either the old or new patch to avoid
        # stale state from overlapping patches.
        files_to_restore=$( { git apply --numstat "$state_p" 2>/dev/null; git apply --numstat "$patch_file" 2>/dev/null; } | awk '{print $3}' | sort -u )
        if [[ -n "$files_to_restore" ]]; then
            git restore $files_to_restore 2>/dev/null || log_err "💥 Failed to restore files for patch $p_name"
        fi
        git apply "$patch_file" || log_err "💥 Failed to apply patch $p_name"
        cp "$patch_file" "$state_p"
    fi
done

cd "$PROJECT_ROOT"

# =============================================================================
# 5. PHASE 3: DEPENDENCY SYNC
# =============================================================================
log_info "📦 Phase 3: Dependency Resolution..."
readonly SYNC_STATE_FILE="${STATE_DIR}/last_sync_v"
[[ "$(cat "$SYNC_STATE_FILE" 2>/dev/null)" != "$VERSION" ]] && {
    log_info "📥 Syncing Gclient..."
    gclient sync -D --nohooks --verbose -j$(nproc)
    log_info "🛠️ Running hooks and Clang update..."
    export DEPOT_TOOLS_WIN_TOOLCHAIN=0
    gclient runhooks
    python3 src/tools/clang/scripts/update.py
    echo "$VERSION" > "$SYNC_STATE_FILE"
}

# =============================================================================
# 6. PHASE 4: COMPILATION
# =============================================================================
log_info "🔨 Phase 4: Compilation Engine..."

prepare_win_toolchain() {
    cd "$SRC_DIR"
    local hash=$(awk -F"['\"]" '/^TOOLCHAIN_HASH/ {print $2}' build/vs_toolchain.py)
    local sdk=$(awk -F"['\"]" '/^SDK_VERSION/ {print $2}' build/vs_toolchain.py)
    log_info "📦 Requested Toolchain: SDK $sdk (Hash $hash)"

    # 🪄 FIX: Must mount CIOPFS first, before anything else!
    if ! mountpoint -q "${PROJECT_ROOT}/win_toolchain/vs_files"; then
        mkdir -p "${PROJECT_ROOT}/win_toolchain/vs_files.ciopfs" "${PROJECT_ROOT}/win_toolchain/vs_files"
        # Removed nonempty to ensure mount on truly empty directories
        ciopfs -o use_ino,allow_other "${PROJECT_ROOT}/win_toolchain/vs_files.ciopfs" "${PROJECT_ROOT}/win_toolchain/vs_files"
    fi

    local dest="${PROJECT_ROOT}/win_toolchain/vs_files/${hash}"
    if [[ ! -d "$dest" ]]; then
        local url="https://github.com/naminx/chromium-mv2/releases/download/${sdk}/${hash}.7z"
        log_info "📥 Downloading toolchain from $url..."
        curl -L -o "${PROJECT_ROOT}/tc.7z" "$url"
        mkdir -p "$dest"
        # Now when extracted, it passes through ciopfs and becomes fully case-insensitive!
        7z x -p"${GITHUB_TOKEN}" "${PROJECT_ROOT}/tc.7z" -o"$dest"
        rm "${PROJECT_ROOT}/tc.7z"
    fi

    export DEPOT_TOOLS_WIN_TOOLCHAIN=1
    cat << JSON | write_if_changed "build/win_toolchain.json"
{ "path": "$dest", "version": "$hash", "win_sdk": "$dest/windows kits/10", "wdk": "$dest/wdk", "runtime_dirs": [ "$dest/sys64", "$dest/sys32" ] }
JSON
    # ... (vs_toolchain.py hack section, same as before) ...    # Suppress vs_toolchain.py Update (Protect against DAG tampering)
    if grep -q "def Update(" build/vs_toolchain.py && ! grep -q "return 0 # Manie" build/vs_toolchain.py; then
        # 🪄 Time Flow Isolation: save old mtime -> edit file -> restore old mtime
        touch -r build/vs_toolchain.py /tmp/vs_time_hack
        sed -i "/def Update(/a \  return 0 # Manie" build/vs_toolchain.py || log_err "💥 Failed to stub vs_toolchain.py"
        touch -r /tmp/vs_time_hack build/vs_toolchain.py
    fi
    cd "$PROJECT_ROOT"
}

[[ "$TARGET" == "win" || "$TARGET" == "all" ]] && prepare_win_toolchain

if [[ "$SYNC_ONLY" -eq 1 ]]; then
    log_info "✅ Sync Complete. (du -s src: $(du -s src | awk '{print $1}'))"
    exit 0
fi

# =============================================================================
# 7. RESOURCE ALLOCATION (The Resilient Engine)
# =============================================================================
log_info "⚙️ Allocating Resources..."

# 🪄 1. Determine job count (for i3-12100: 8 threads)
readonly CPU_CORES=$(nproc)
ninja_jobs=$CPU_CORES

# 🪄 2. Set scheduler priorities
# nice -n 19: lowest CPU priority (User Space)
# ionice -c 3: idle I/O priority (prevents system freeze from I/O wait)
readonly NINJA_CMD="nice -n 19 ionice -c 3 ninja"

log_info "📊 Resource Strategy: $ninja_jobs threads with Low Priority (Nice 19 + Idle I/O)"

# The Invariant: the fastest optimized GN args
# Note: use_thin_lto=false requires is_cfi=false
readonly COMMON_ARGS="is_debug=false is_official_build=true chrome_pgo_phase=0 use_thin_lto=true is_cfi=false use_lld=true symbol_level=0 blink_symbol_level=0 v8_symbol_level=0 proprietary_codecs=true ffmpeg_branding=\"Chrome\""

# Functional Setup & Execution
compile_and_release() {
    local readonly os_target="$1"
    local readonly out_dir="${SRC_DIR}/out/${os_target}"
    local readonly gn_args="$COMMON_ARGS target_os=\"${os_target}\""
    local target_name=""
    local release_file=""

    if [[ "$os_target" == "linux" ]]; then
        target_name="chrome chrome/installer/linux:stable_deb"
        # 🪄 Fix: Remove old debian packages to avoid 'ls' returning multiple files
        rm -f "${out_dir}"/chromium-browser-stable_*.deb
    elif [[ "$os_target" == "win" ]]; then
        target_name="mini_installer"
    fi

    log_info "⚙️ Configuring GN for $os_target..."
    # 🪄 Fix: create all directories upfront before writing files
    mkdir -p "$out_dir"
    echo "$gn_args" | write_if_changed "${out_dir}/args.gn"

    # 🪄 Isolate State Mutation: run gn gen in a subshell to avoid affecting the main working directory
    if [[ ! -f "${out_dir}/build.ninja" ]]; then
        ( cd "$SRC_DIR" && gn gen "$out_dir" )
    fi

    log_info "🔥 Igniting Ninja Engine ($ninja_jobs jobs) for $os_target..."
    # 🪄 Invoke the wrapped NINJA_CMD
    $NINJA_CMD -C "$out_dir" $target_name -j$ninja_jobs

    log_info "📦 Packaging and Uploading Artifacts..."
    local staging_dir="${PROJECT_ROOT}/release-staging"
    mkdir -p "$staging_dir"
    if [[ "$os_target" == "linux" ]]; then
        src_file=$(ls -t ${out_dir}/chromium-browser-stable_*.deb 2>/dev/null | head -n 1 || true)
        if [[ -n "$src_file" ]]; then
            release_file="${staging_dir}/chromium-mv2-${VERSION}.deb"
            cp "$src_file" "$release_file"
        fi
    elif [[ "$os_target" == "win" ]]; then
        src_file=$(ls -t ${out_dir}/mini_installer.exe 2>/dev/null | head -n 1 || true)
        if [[ -n "$src_file" ]]; then
            release_file="${staging_dir}/chromium-mv2-${VERSION}.exe"
            cp "$src_file" "$release_file"
        fi
    fi

    if [[ -n "$release_file" && -n "${GITHUB_TOKEN:-}" ]]; then
        export GH_TOKEN="$GITHUB_TOKEN"
        gh release upload "${VERSION}" "$release_file" --clobber --repo naminx/chromium-mv2 2>/dev/null \
            || gh release create "${VERSION}" "$release_file" --repo naminx/chromium-mv2 \
            --title "Chromium ${VERSION} with MV2 support for Linux and Windows" --notes ""
        log_info "🚀 Successfully released $(basename "$release_file")"
    else
        log_warn "⚠️ No artifact found or GITHUB_TOKEN missing. Skipping GitHub Release."
    fi
}

# 🚀 Fire it up!
if [[ "$TARGET" == "deb" || "$TARGET" == "all" ]]; then compile_and_release "linux"; fi
if [[ "$TARGET" == "win" || "$TARGET" == "all" ]]; then compile_and_release "win"; fi

log_info "✅ === BUILD ENGINE FINISHED SUCCESSFULLY ==="
