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

## Using the Cache

```nix
# In your NixOS configuration or ~/.config/nix/nix.conf:
nix.settings = {
  substituters = [ "https://my-chromium.cachix.org" ];
  trusted-public-keys = [ "my-chromium.cachix.org-1:..." ];
};
```

Then install with:

```bash
nix-env -iA chromium -f https://github.com/<you>/chromium-mv2/archive/main.tar.gz
# or in a NixOS configuration:
# environment.systemPackages = [ (import (fetchTarball "...") {}) ];
```

## Why Direct nixpkgs Patching?

The standard NixOS `chromium` package does not support appending to `patches` via
`overrideAttrs` because the patches list is deeply embedded in `common.nix` (it
references local files via relative `./patches/` paths, which are not easily overridable).

Our solution:
1. Sparse-checkout *only* the chromium package directory from nixpkgs
2. Programmatically patch `common.nix` to append our custom patches
3. Build using this locally modified nixpkgs
