#!/usr/bin/env bash
# view-manie-log.sh — The Telemetry Observer
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${PROJECT_ROOT}/logs"

if [[ ! -d "$LOG_DIR" ]]; then
    echo -e "[\e[31mERROR\e[0m] Log directory not found! Has the engine started?"
    exit 1
fi

# The Query: หาไฟล์ log ที่ใหม่ที่สุด (เรียงด้วย -t แล้วดึงบรรทัดแรกมา)
readonly LATEST_LOG=$(ls -t "$LOG_DIR"/build-*.log 2>/dev/null | head -n 1 || true)

if [[ -z "$LATEST_LOG" ]]; then
    echo -e "[\e[33mWARN\e[0m] No logs found yet. The engine might still be initializing..."
    exit 0
fi

echo -e "[\e[32mINFO\e[0m] Tailing live telemetry: $(basename "$LATEST_LOG")"
echo -e "[\e[34mTIP\e[0m] Press Ctrl+C to stop watching (The build will continue in the background)\n"

# The Observer: tail -f จะติดตามการเปลี่ยนแปลงของไฟล์แบบ Real-time
tail -f "$LATEST_LOG"
