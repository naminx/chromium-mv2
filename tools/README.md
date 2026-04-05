# tools/

One-time-use Python scripts for packaging the Windows cross-compilation toolchain
on a Linux (NixOS) host. These scripts are **not** part of the Chromium or Nix
build pipeline — they are run manually, once, to produce the `<sha1>.zip` toolchain
archive that the remote Hetzner build servers consume.

---

## host_packager.py

**When to run:** On the local NixOS host, when a locally-mounted Windows drive
(`/home/namin/sources/chromium-mv2/c/`) contains an installed copy of Visual Studio
2022 BuildTools and the Windows 10 SDK.

**What it does:**

1. Monkeypatches `subprocess.check_output` so that calls to `vswhere.exe` and
   `reg query` (Windows-only commands) return fake responses pointing at the
   Linux-mounted paths:
   - VS path: `/home/namin/sources/chromium-mv2/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools`
   - SDK path: `/home/namin/sources/chromium-mv2/c/Program Files (x86)/Windows Kits/10`
2. Loads `/tmp/depot_tools/win_toolchain/package_from_installed.py` at runtime and
   patches it in-memory to fix Windows-only path assumptions:
   - Replaces backslash path separators with forward slashes.
   - Fixes case-insensitive filesystem access via a custom `ExpandWildcards`.
   - Corrects `SUPPORTED_VS_VERSION` / `SUPPORTED_VS_FILESYSTEM_NAME` (upstream
     targets VS 2026; we use VS 2022).
3. Injects `sys.argv` and calls the patched code as if running:
   ```
   package_from_installed.py 2022 -w 10.0.26100.0 --noarm
   ```
   Output is a `<sha1>.zip` in the current working directory.

**Prerequisites:**
- `depot_tools` checked out at `/tmp/depot_tools`
- Windows drive mounted (e.g. via `mount`) at the paths above
- Run from the repo root: `python tools/host_packager.py`

---

## run_packager.py

**When to run:** Inside the Docker build container on Hetzner (where the Windows
drive is bind-mounted at `/windrive` and `depot_tools` is at `/depot_tools`).

**What it does:** Same overall approach as `host_packager.py`, but with different
paths suited to the Docker environment:

- VS path: `/windrive/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools`
- SDK path: `/windrive/Program Files (x86)/Windows Kits/10`
- Reads `package_from_installed.py` from `/depot_tools/win_toolchain/`

Applies the same in-memory patching of backslash separators and VS version strings,
then calls `exec(code, globals())` leaving `sys.argv` to be set by whatever invokes
this script (or set manually before calling).

**Prerequisites:**
- `depot_tools` at `/depot_tools`
- Windows drive bind-mounted at `/windrive`
- Run from the repo root: `python tools/run_packager.py`

---

## Upstream Reference Files (project root)

These files live in the project root and are **not run directly** from this repo.
They are upstream copies kept for reference, diffing, and as the source that
`host_packager.py` / `run_packager.py` load and patch at runtime.

### ../linux_package_toolchain.py

**Origin:** Copy of `depot_tools/win_toolchain/package_from_installed.py` as it
existed when this project was set up (same content as `package_from_installed.py`
below — kept as a named alias for clarity).

**What it does:** Given an installed copy of Visual Studio 2022 BuildTools and the
Windows 10 SDK, walks both trees and zips the required subset of files into
`out.zip`, then renames it to `<sha1>.zip` using the same hash algorithm that
`get_toolchain_if_necessary.py` uses to verify downloads. This is the canonical
upstream packaging script that our patching wrappers (`host_packager.py`,
`run_packager.py`) load and adapt for Linux.

**Key internals:**
- `GetVSPath()` — calls `vswhere.exe` (mocked on Linux by our wrappers).
- `BuildFileList()` — enumerates VS CRT, DIA SDK, ATL/MFC, and SDK headers/libs.
- `GenerateSetEnvCmd()` — synthesises the `SetEnv.cmd` / `SetEnv.*.json` batch files.
- `RenameToSha1()` — extracts the zip to a temp dir, hashes it with SHA-1, renames.
- CLI: `python linux_package_toolchain.py 2022 -w 10.0.26100.0 [--noarm]`
  (Windows only; use `tools/host_packager.py` or `tools/run_packager.py` on Linux).

### ../package_from_installed.py

**Origin:** Same upstream source as `linux_package_toolchain.py`; identical content.
Present as the canonical depot_tools filename so patches and diffs against the
upstream repo remain readable.

### ../vs_toolchain.py

**Origin:** Copy of `build/vs_toolchain.py` from the Chromium source tree
(hash `e4305f407e`, SDK `10.0.26100.0`).

**What it does:** Manages the depot_tools-downloaded VS toolchain for Chromium GN
builds. Used by `gclient runhooks` and the GN build system on both Windows and
cross-compiling Linux hosts.

**Key entry points (called by the build system, not manually):**
- `update` — downloads or verifies the toolchain zip via `get_toolchain_if_necessary.py`.
- `get_toolchain_dir` — prints GN variables (`vs_path`, `sdk_path`, `vs_version`, …)
  read by `build/toolchain/win/setup_toolchain.py`.
- `copy_dlls` — copies VS CRT and debugger DLLs into the build output directory.

**Kept here for:** inspecting which toolchain hash / SDK version Chromium expects,
diffing against our patched copy, and understanding what the build system calls.
