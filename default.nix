# Build customized Chromium using our patched Chromium nixpkgs files.
#
# Usage:
#   ./fetch-nixpkgs    # fetch nixpkgs sparse checkout into ./nixpkgs/ (once)
#   ./patch-nixpkgs   # inject custom patches into nixpkgs common.nix (idempotent)
#   nix-build          # build
#
# nixpkgs-pin.json is updated automatically by CI after each successful build
# to record the exact nixpkgs commit used, so the derivation hash is identical
# between CI and your local machine — allowing Cachix to serve the binary.

let
  pin = builtins.fromJSON (builtins.readFile ./nixpkgs-pin.json);

  nixpkgsSrc = builtins.fetchTarball {
    url    = "https://github.com/NixOS/nixpkgs/archive/${pin.rev}.tar.gz";
    sha256 = pin.sha256;
  };

  pkgs = import nixpkgsSrc { };

  # Our sparse-checked-out + patched chromium package directory.
  chromiumDir = ./nixpkgs/pkgs/applications/networking/browsers/chromium;

in
  pkgs.callPackage chromiumDir { }
