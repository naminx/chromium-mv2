# Build & Maintenance Scripts

Shell scripts for remote builds, cross-compilation, toolchain packaging, and log monitoring.

## Build Scripts

### [build-nix-on-hetzner.sh](./build-nix-on-hetzner.sh)

Builds Chromium in a "nix way" on a remote Hetzner cloud server and pushes the result to Cachix.

- **Usage:** `./build-nix-on-hetzner.sh <HETZNER_IP> <CACHIX_TOKEN> [HETZNER_API_TOKEN]`
- **Note:** If an API token is provided, the server will self-destruct after a successful build.
- **Critical:** Ensure all local patches are committed and pushed to GitHub before running, as the remote server builds from the GitHub repository.

### [build-binaries-on-hetzner.sh](./build-binaries-on-hetzner.sh)

Builds both Linux (.deb) and Windows (.exe) binaries on a remote Hetzner cloud server using Docker. This script uses snapshots for persistence.

- **Usage:** `./build-binaries-on-hetzner.sh <HETZNER_IP> <CHROMIUM_VERSION> [--from-cache <PREV_VERSION>] [--api <TOKEN>]`
- **Features:**
  - Produces both a Debian package (`.deb`) and a Windows installer (`.exe`).
  - Uploads both artifacts to Google Drive upon success.
  - Creates a Hetzner snapshot of the server disk to preserve the ~30 GB source tree for the next build.
  - Automatically deletes the server after the snapshot is finished.
- **Note:** Snapshotting is significantly faster than archiving and uploading the source tree to Google Drive.

### [build-docker.sh](./build-docker.sh)

Builds Chromium for both Linux (Debian) and Windows using a Docker or Podman container.

- **Usage:** `./build-docker.sh <CHROMIUM_VERSION> [--shallow]`
- **Output:** Produces both a `chromium-browser_*.deb` (Linux) and a `mini_installer.exe` (Windows).
- **Persistence:** Uses a Docker volume (`chromium-mv2-src`) to persist the source tree and enable incremental builds.

### [build-win-on-hetzner.sh](./build-win-on-hetzner.sh)

Automates the Windows Chromium build on a Hetzner server, utilizing Google Drive for toolchain and artifact storage.

- **Usage:** `./build-win-on-hetzner.sh <HETZNER_IP> <CHROMIUM_VERSION> [--from-cache <PREV_VERSION>] [--api <TOKEN>]`
- **Features:**
  - `--from-cache`: Downloads previous build artifacts from Google Drive to allow incremental compilation.
  - `--api`: Provides a Hetzner API token to trigger automatic server self-destruction upon completion.
- **Prerequisites:** Requires `rclone` configured with a remote pointing to Google Drive.

## Monitoring

### [tail-hetzner.sh](./tail-hetzner.sh)

Streams build logs from a remote Hetzner server.

- **Usage:** `./tail-hetzner.sh <HETZNER_IP>`
- **Features:** Includes SSH keepalives every 60 s and an idle timeout (60 min) to prevent disconnection during long, silent build steps (e.g. the final link or a large git clone). Automatically detects a stalled/crashed build and restarts it; pressing Ctrl+C exits without killing the background build.

## Toolchain Packaging

### [do_package.sh](./tools/do_package.sh)

Entry-point script run **inside** the `build-docker.sh` container to package the Windows VS 2022 toolchain into a `<sha1>.zip` archive.

- **What it does:**
  1. Installs `ciopfs` (case-insensitive overlay FS).
  2. Mounts `/real_c` (the Windows C: drive bind-mount) as a case-insensitive filesystem at `/windrive`.
  3. Changes into `/out` and invokes `tools/run_packager.py` to produce the zip.
- **Not run directly** — called by `build-docker.sh` automatically.
- See [`tools/README.md`](./tools/README.md) for details on `run_packager.py`.
