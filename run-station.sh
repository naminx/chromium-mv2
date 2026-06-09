#!/usr/bin/env bash
# run-station.sh — The Host-Side Gatekeeper & Docker State Machine
set -euo pipefail

# =============================================================================
# 1. CONSTANTS (Immutable State)
# =============================================================================
readonly IMAGE_NAME="manie-chromium-station"
readonly DOCKERFILE="Dockerfile"

# 🪄 Fix 1: Dynamic Path Binding - ดึง path ปัจจุบันเสมอ ไม่ว่าจะย้ายโฟลเดอร์ไปไหน
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info() { echo -e "[\e[34mHOST\e[0m] \e[32mINFO:\e[0m $1"; }
log_warn() { echo -e "[\e[34mHOST\e[0m] \e[33mWARN:\e[0m $1"; }
log_err() { echo -e "[\e[34mHOST\e[0m] \e[31mERROR:\e[0m $1"; }

# =============================================================================
# 2. PHASE 0: DOCKER STATE MACHINE (The Builder)
# =============================================================================
if [[ ! -f "$DOCKERFILE" ]]; then
    echo "ERROR: $DOCKERFILE not found in current directory!" >&2
    exit 1
fi

readonly CURRENT_HASH=$(md5sum "$DOCKERFILE" | awk '{print $1}')

# 🪄 Fix 2: Safe Memory Access - ป้องกัน Go Template Panic ถ้า Image ไม่มี Label
STORED_HASH=$(docker image inspect "$IMAGE_NAME" -f '{{ if .Config.Labels }}{{ index .Config.Labels "dockerfile_hash" }}{{ end }}' 2>/dev/null || true)
[[ -z "$STORED_HASH" ]] && STORED_HASH="missing"

if [[ "$CURRENT_HASH" != "$STORED_HASH" ]]; then
    if [[ "$STORED_HASH" == "missing" ]]; then
        log_info "No existing image found. Bootstrapping $IMAGE_NAME..."
    else
        log_info "Dockerfile mutation detected ($STORED_HASH -> $CURRENT_HASH). Rebuilding..."
    fi

    docker build \
        --label "dockerfile_hash=$CURRENT_HASH" \
        -t "$IMAGE_NAME" .

    log_info "Image state synchronized successfully."
else
    log_info "Stationary State: Docker image is up-to-date. Skipping build."
fi

# =============================================================================
# 3. PHASE 1: EXECUTION (The Ignition)
# =============================================================================
log_info "Neutralizing previous engine state..."
docker rm -f manie-engine 2>/dev/null || true

log_info "Igniting Manie Chromium Station in DETACHED mode..."

# 🪄 เหลือแค่อันเดียวพอค่ะ (The High-Fidelity One)
# 🪄 Fix: ปลดล็อก File Descriptor Limit ตามโค้ดเก่า
docker run -d \
    --name "manie-engine" \
    --init \
    --cap-add SYS_ADMIN --device /dev/fuse \
    --user "$(id -u):$(id -g)" \
    --ulimit nofile=65536:65536 \
    -v "${PROJECT_ROOT}:/chromium" \
    -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
    -e CHROMIUM_MV2_API_KEY="${CHROMIUM_MV2_API_KEY:-}" \
    -e CHROMIUM_MV2_CLIENT_ID="${CHROMIUM_MV2_CLIENT_ID:-}" \
    -e CHROMIUM_MV2_CLIENT_SECRET="${CHROMIUM_MV2_CLIENT_SECRET:-}" \
    "$IMAGE_NAME" /chromium/build-engine.sh "$@"

log_info "Engine spawned. Validating health..."
sleep 2

# ตรวจสอบสุขภาพเครื่องจักร (PHASE 1 ใน run-station.sh)
if ! docker ps --filter "name=manie-engine" --format '{{.Names}}' | grep -q "manie-engine"; then
    log_err "Engine crashed! High-fidelity error log below:"
    echo -e "\e[2m----------------------- [ CONTAINER STDOUT ] -----------------------\e[0m"

    # ดึง Log ออกมา
    docker logs "manie-engine" 2>&1

    # 🪄 กุญแจสำคัญของพี่มิน: เส้นยืนยันความสมบูรณ์ของกระบวนการ
    echo -e "\e[2m----------------------- [ END OF ENGINE LOG ] ----------------------\e[0m"

    # แถม: ตรวจสอบสาเหตุจากระดับ Kernel/Docker Daemon
    exit_code=$(docker inspect "manie-engine" --format '{{.State.ExitCode}}' 2>/dev/null || echo "unknown")
    log_warn "Engine process terminated with Exit Code: $exit_code"

    # ล้างซากทันทีหลังจากดึงข้อมูลเสร็จ (ถ้าต้องการความสะอาด)
    # docker rm -f manie-engine >/dev/null 2>&1

    exit 1
fi

log_info "Engine is alive and kicking! 🔥"
