# Chromium Build Refactor Plan: Single Source of Truth

## Core Philosophy
1.  **Single Source of Truth:** All Chromium-specific logic (Sync, Toolchains, Patches, Compilation) lives exclusively in `build-docker.sh`.
2.  **Infrastructure Orchestration:** `build-hetzner.sh` manages ONLY servers, volumes, and handoffs. It is "Chromium-blind."
3.  **Proven Performance:** Restore the exact high-speed, high-resilience sequence used in the successful monolith.
4.  **Security:** Use `HCLOUD_TOKEN` and `GITHUB_TOKEN` environment variables.
5.  **Mandatory "WHY" Documentation:** Every technical safeguard (Swap, GC, Memory Caps) MUST have a detailed comment explaining *why* it exists. **Removing these comments is considered a technical regression.**
6.  **Semantic Sentinels:** Use specific keywords (`BASH`, `PYTHON`, `JSON`, `DOCKERFILE`) for `cat <<` delimiters to ensure editors correctly highlight nested code.

---

## 1. Hardware Selection Strategy

### Manager (Seed) Node
*   **Type:** Fixed as `cx23` ($0.008/hr).
*   **WHY:** Synchronization and toolchain downloads are primarily I/O and network bound. Paying for extra CPU cores is wasted money during the 1-2 hour preparation phase.

### Beast (Worker) Node
*   **Production Type:** `ccx63` (48-core Dedicated CPU).
*   **WHY:** Chromium compilation is extremely parallel. 48 cores and 192GB RAM allow for a 100GB `tmpfs` (RAM disk) for the `out/` directory, drastically reducing build times and saving Volume SSD life.
*   **Debug Mode (The "Domestic Cat"):** Triggered by `--cheap` flag. Forces the Beast to be a `cx23`.
*   **WHY:** Essential for debugging the handoff and compilation logic without incurring the high cost of a 48-core machine. It allows us to verify the system is stable for pennies before scaling up.

---

## 2. The Build Engine (`build-docker.sh`)
This script becomes a **Two-Phase State Machine**.

### Phase 1: Host-Side Preparation (Runs on Manager/Local Host)
*   **Memory Resilience:** Initialize a 20GB Swap file and set Git memory limits (`pack.windowMemory 256m`, `pack.threads 1`) immediately. This allows the cheap 4GB server to handle 300k+ file objects without being OOM-killed.
*   **Background Trash GC:** If a sync fails, rename the directory to `.trash_$TIMESTAMP` and run `nohup rm -rf &` in the background. **WHY:** This allows the next retry to start INSTANTLY without waiting for the kernel to delete 100GB of files.
*   **High-Speed Hybrid Sync:**
    *   Use raw `git fetch --depth 1 --progress` for the 30GB `src` repo. **WHY:** Bypasses the silent gclient wrapper and gives you the "terminal status light" (percentage bars).
    *   Retry loop: 3 attempts with the Background Trash logic.
*   **Incremental Intelligence:**
    *   Use `.last_built_version` and `git diff | xargs touch` to preserve timestamps.
    *   **WHY:** Allows minor version upgrades to finish in minutes by skipping identical object files.
*   **Universal Toolchain:**
    *   Never download Windows SDK from Google (prevents 401 errors).
    *   Extract the custom `42b5b0689e.7z` toolchain archive.
    *   Write the `win_toolchain.json` using a `JSON` sentinel.
    *   Use the `DEPOT_TOOLS_WIN_TOOLCHAIN=0` sequence lock.
*   **Early Exit:** If `--setup-only` is passed, exit successfully.

### Phase 2: Container-Side Compilation (Runs inside Docker)
*   The script launches itself inside Docker (`docker run -i ... bash "$0"`).
*   **Smart Skip:** Skips Phase 1 if the volume is already warm.
*   **Patching:** Resets the tree to a clean state and applies all `patches/*.patch`.
*   **Ninja Compilation:** Performs `gn gen` and `ninja` for the requested target.
*   **Resource Management:** Automatically caps concurrent links and jobs based on server RAM.

---

## 3. The Cloud Orchestrator (`build-hetzner.sh`)

### Infrastructure Lifecycle
*   **Nuclear Cleanup:** Implement `--cleanup` to purge all project-labeled build servers and volumes.
*   **Safety Check:** Use `curl` to verify `GITHUB_TOKEN` validity before accepting `--remove-volume`.
*   **Delegation:** Performs NO Chromium tasks. It only executes `./build-docker.sh` on the remote server.

---

## 4. Implementation Steps
1.  **Step 1:** Implement the High-Resilience Phase 1 in `build-docker.sh`.
2.  **Step 2:** Implement the Recursive Phase 2 in `build-docker.sh`.
3.  **Step 3:** Strip `build-hetzner.sh` down to a pure orchestrator.
4.  **Step 4:** Perform an Integrated Test run.
