# chromium-mv2

A customized NixOS build of Chromium with extra patches, automatically built and published to Cachix.

## Patches

Custom patches live in the `patches/` directory:

| Patch | Description |
|-------|-------------|
| `keep-window-open.patch` | Creates a new tab instead of closing the window when the last tab is closed |

## Project Layout

```
.
├── fetch-nixpkgs       # Fetches nixpkgs sparse checkout into ./nixpkgs/
├── patch-nixpkgs       # Patches nixpkgs/pkgs/.../chromium/common.nix with our custom patches
├── default.nix         # Top-level Nix expression — builds chromium
├── patches/            # Custom patch files applied on top of stock Chromium
└── .github/
    └── workflows/
        └── build.yml   # GitHub Actions: build + push to Cachix
```

## Local Build

```bash
# 1. Fetch a sparse nixpkgs checkout (only the Chromium package files)
./fetch-nixpkgs

# 2. Inject our custom patches into nixpkgs (idempotent)
./patch-nixpkgs

# 3. Build
nix-build
```

The `result` symlink points to the built Chromium package.

## Adding More Patches

Simply drop a `.patch` file into the `patches/` directory. The `patch-nixpkgs` script
automatically picks up **all** `*.patch` files in that directory and inserts them into
`nixpkgs/.../chromium/common.nix`.

Re-run `patch-nixpkgs` after adding a new patch (or re-run `fetch-nixpkgs && patch-nixpkgs`
to start from a fresh nixpkgs checkout).

## GitHub Actions / Cachix Setup

The workflow (`.github/workflows/build.yml`) needs the following configured in your GitHub repository:

### Repository Variables (`Settings → Secrets and variables → Actions → Variables`)

| Name | Value |
|------|-------|
| `CACHIX_CACHE` | Your Cachix cache name (e.g. `my-chromium`) |

### Repository Secrets (`Settings → Secrets and variables → Actions → Secrets`)

| Name | Value |
|------|-------|
| `CACHIX_AUTH_TOKEN` | Your Cachix auth token (from `cachix authtoken generate`) |
| `CACHIX_PUBLIC_KEY` | Your cache's public key (from `cachix use <cache-name>` output) |

### Quick Cachix Setup

```bash
# Install cachix
nix-env -iA cachix -f https://cachix.org/api/v1/install

# Authenticate
cachix authtoken <your-personal-token>

# Create a cache (if you don't have one yet)
cachix create my-chromium

# Get your cache public key
cachix use my-chromium
```

## Using the Cachix Binary in NixOS

For Nix to fetch the pre-built binary from Cachix instead of compiling locally,
the derivation hash computed on your machine must **exactly match** what CI built.
This is guaranteed by `nixpkgs-pin.json`, which CI updates after each successful
build to record the exact nixpkgs commit + sha256 it used.

**Workflow on your local machine:**

```bash
# 1. Pull the repo (gets the latest nixpkgs-pin.json from CI)
git -C ~/sources/chromium-mv2 pull

# 2. Fetch nixpkgs sparse checkout + patch it
bash ~/sources/chromium-mv2/fetch-nixpkgs
bash ~/sources/chromium-mv2/patch-nixpkgs

# 3. nixos-rebuild will now fetch from Cachix instead of compiling
sudo nixos-rebuild switch
```

**`configuration.nix` snippet:**

```nix
{ config, pkgs, lib, ... }:

let
  # Import the custom Chromium — uses the exact same pinned nixpkgs as CI,
  # so Cachix serves the pre-built binary instead of recompiling.
  chromium-custom = import /home/namin/sources/chromium-mv2 { };
in
{
  # Tell Nix to use your Cachix cache
  nix.settings = {
    substituters      = [ "https://namin.cachix.org" ];
    trusted-public-keys = [ "namin.cachix.org-1:PASTE_PUBLIC_KEY_HERE" ];
  };

  environment.systemPackages = [ chromium-custom ];
}
```

> **Why `nixpkgs-pin.json`?** If `default.nix` used `<nixpkgs>` (impure),
> CI and your machine might evaluate against different nixpkgs channel snapshots,
> producing different hashes — and Cachix would be a miss. The pin file locks
> both to the identical commit, guaranteeing a cache hit.

## Why Direct nixpkgs Patching?

The standard NixOS `chromium` package does not support appending to `patches` via
`overrideAttrs` because the patches list is deeply embedded in `common.nix` (it
references local files via relative `./patches/` paths, which are not easily overridable).

Our solution:
1. Sparse-checkout *only* the chromium package directory from nixpkgs
2. Programmatically patch `common.nix` to append our custom patches
3. Build using this locally modified nixpkgs
