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

## Relationship to upstream scripts

`linux_package_toolchain.py` and `package_from_installed.py` in the repo root are
**reference copies** of upstream depot_tools scripts. They are not run directly;
instead `host_packager.py` and `run_packager.py` load and patch them at runtime
to work on a Linux filesystem.

`vs_toolchain.py` is a reference copy of the upstream Chromium `vs_toolchain.py`
build script, kept for inspection/diffing purposes.
