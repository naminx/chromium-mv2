# Chromium Build & Orchestration

Modern, volume-aware build system for high-performance Chromium cross-compilation on Hetzner Cloud.

## Core Scripts

### [build-hetzner.sh](./build-hetzner.sh)

The master orchestrator. It manages the full lifecycle: server creation, volume mounting, source syncing, and platform handoff.

- **Usage:** `./build-hetzner.sh <VERSION> --target <deb|win> --api-key <TOKEN> [options]`
- **Key Options:**
  - `--cheap`: Use a `cx23` (4-core) for both Manager and Beast. Ideal for testing.
  - `--skip-sync`: Bypass the Manager and launch the Beast immediately on an existing volume.
  - `--reuse-beast <IP>`: **Rescue Mode**. Repairs and resumes a build on an existing server.
  - `--remove-volume`: Deletes the persistent volume and the server upon success.
- **The "Universal Volume" Strategy:**
  The Seed server always prepares the volume for both Linux and Windows. This allows you to build a Linux package, then immediately build a Windows installer on the same server without re-downloading toolchains.

### [build-docker.sh](./build-docker.sh)

The build engine. Runs inside a Docker container to provide a reproducible build environment.

- **Features:**
  - **Self-Healing:** Automatically detects if the target changed and repairs toolchains.
  - **Smart Sync:** Skips the 110GB sync if run inside the cloud orchestrator.
  - **Resource Aware:** Automatically caps Ninja jobs based on available RAM to prevent OOM kills.
  - **Case-Insensitive:** Uses `ciopfs` to handle Windows headers on Linux filesystems.

### [tail-hetzner.sh](./tail-hetzner.sh)

The monitoring tool. Automatically discovers active build servers and streams their logs.

- **Usage:** `./tail-hetzner.sh` (Auto-detects IP)
- **Features:** Surrvives server handoffs and rescues. Streams `/var/log/build.log` with high-resolution timestamps.

---

## Build Workflows

### 1. The Integrated Production Run

To build both platforms with maximum efficiency:

```bash
# Step A: Build Linux (Creates the Universal Volume)
./build-hetzner.sh 147.0.7727.101 --target deb --api-key $HCLOUD_TOKEN --gh-token $GH_TOKEN

# Step B: Build Windows (Reuses the same server and volume)
./build-hetzner.sh 147.0.7727.102 --target win --api-key $HCLOUD_TOKEN --reuse-beast <BEAST_IP> --remove-volume
```

### 2. The Cheap Test

To verify code changes without spending money:

```bash
./build-hetzner.sh 147.0.7727.103 --target deb --api-key $HCLOUD_TOKEN --cheap
```

---

## Architecture

1.  **Manager (Seed):** A cheap `cx23` server. It mounts the persistent volume, syncs the 110GB source, and downloads the "Universal" toolchains.
2.  **Handoff:** The Manager flushes data to the Volume, detaches it, and spawns the Beast.
3.  **Beast:** A powerful `ccx63` (48-core) server. It mounts the volume and starts the heavy compilation immediately.
4.  **Persistence:** All source code and build artifacts live on a **Hetzner Volume**, ensuring that a server crash never loses your progress.
