# Chromium MV2

A specialized Chromium build pipeline designed for high-performance cross-compilation on Hetzner Cloud and local NixOS machines. This project focuses on maintaining Manifest V2 support and other custom patches.

## The Modern Build Architecture

The project is refactored into a "Single Source of Truth" architecture:

1.  **The Brain (`build-docker.sh`):** Contains 100% of the Chromium intelligence. It handles synchronization, toolchain preparation, patching, and Ninja compilation. It is a two-phase state machine that runs natively on the host for speed (Sync/Toolchains) and inside Docker for reproducibility (Compilation).
2.  **The Body (`build-hetzner.sh`):** A pure infrastructure orchestrator. It manages the Hetzner server lifecycle, volume mounting, and server-to-server handoffs. It has no internal knowledge of Chromium.

---

## 🔐 Environment Setup

Authentication is handled via standard environment variables. You must set these before running any build scripts:

```bash
export HCLOUD_TOKEN="your_hetzner_api_token"
export GITHUB_TOKEN="your_github_token"   # Required for releases and --remove-volume
```

---

## 🚀 Cloud Build Workflows (Hetzner)

### 1. The Integrated Production Run
This perform the 110GB sync on a cheap "Manager" node, then hands off the volume to a 48-core "Beast" for compilation.

```bash
# Target options: deb, win, or all
./build-hetzner.sh 147.0.7727.101 --target all
```

### 2. The "Domestic Cat" (Cheap Test)
Verifies the entire pipeline (Sync + Compilation) using only cheap `cx23` servers.

```bash
./build-hetzner.sh 147.0.7727.101 --target deb --cheap
```

### 3. Monitoring Progress
Use the tail script to stream logs from the active server. It automatically discovers the correct IP.

```bash
./tail-hetzner.sh
```

### 4. Nuclear Cleanup
Deletes ALL build servers and the persistent volume associated with the project.

```bash
./build-hetzner.sh --cleanup
```

---

## 💻 Local Build Workflow

The "Brain" script is designed to be fully functional on your local NixOS or Linux machine.

```bash
# Syncs code locally and builds inside a Docker container
./build-docker.sh 147.0.7727.101 --target all
```

---

## 🩹 Patches

Custom patches live in the `patches/` directory. They are applied automatically during the build phase.

| Patch                    | Description                                                                 |
| ------------------------ | --------------------------------------------------------------------------- |
| `keep-window-open.patch` | Creates a new tab instead of closing the window when the last tab is closed |
| `manifest-v2.patch`      | Restores Manifest V2 support in newer Chromium versions                     |
| `google-sync.patch`      | Enables custom Google Sync API keys                                         |

---

## 📂 Project Layout

```
.
├── build-docker.sh         # THE BRAIN: Sync, Toolchains, Compilation
├── build-hetzner.sh        # THE BODY: Infrastructure orchestration
├── tail-hetzner.sh         # THE LOGS: Real-time monitoring
├── REFACTOR_PLAN.md        # Master architectural blueprint
├── GEMINI.md               # Operational Laws (Historical Trauma protection)
├── patches/                # Custom .patch files
├── tools/                  # Toolchain packaging and VS helpers
└── backups/                # Proven monolith backups
```

## 🛠️ Technical Safeguards (The "WHY")

Every technical routine in this project is protected by mandatory documentation in the code. Key safeguards include:
*   **Background Trash GC:** Renames failed checkouts and deletes them in the background to allow instant retries.
*   **Memory Resilience:** Early Swap activation and Git memory caps to survive on 4GB servers.
*   **Incremental Intelligence:** `git diff` based timestamp restoration to save hours of compilation time.
*   **Safe Toolchain Sequence:** Strict `WIN_TOOLCHAIN=0` lock during hooks to prevent unauthorized 401 errors.
