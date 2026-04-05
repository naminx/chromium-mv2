# Build & Maintenance Scripts

Shell scripts for remote builds, cross-compilation, toolchain packaging, and log monitoring.

## Build Scripts

### [build-on-hetzner.sh](./build-on-hetzner.sh)
Builds Chromium on a remote Hetzner cloud server.
- **Usage:** `./build-on-hetzner.sh <HETZNER_IP> <CACHIX_TOKEN> [HETZNER_API_TOKEN]`
- **Note:** If an API token is provided, the server will self-destruct after a successful build.
- **Critical:** Ensure all local patches are committed and pushed to GitHub before running, as the remote server builds from the GitHub repository.

### [build-docker.sh](./build-docker.sh)
Cross-compiles Chromium for Windows using a Docker or Podman container.
- **Usage:** `./build-docker.sh <CHROMIUM_VERSION> [--shallow]`
- **Output:** Produces a `mini_installer.exe` (Windows x64 installer).
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

### [do_package.sh](./do_package.sh)
Entry-point script run **inside** the `build-docker.sh` container to package the Windows VS 2022 toolchain into a `<sha1>.zip` archive.
- **What it does:**
  1. Installs `ciopfs` (case-insensitive overlay FS).
  2. Mounts `/real_c` (the Windows C: drive bind-mount) as a case-insensitive filesystem at `/windrive`.
  3. Changes into `/out` and invokes `tools/run_packager.py` to produce the zip.
- **Not run directly** — called by `build-docker.sh` automatically.
- See [`tools/README.md`](./tools/README.md) for details on `run_packager.py`.
