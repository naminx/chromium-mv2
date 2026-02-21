# Build customized Chromium using our patched Chromium nixpkgs files.
#
# Usage:
#   ./fetch-nixpkgs    # fetch nixpkgs sparse checkout into ./nixpkgs/ (once)
#   ./patch-nixpkgs   # inject custom patches into nixpkgs common.nix (idempotent)
#   nix-build          # build
#
# Uses <nixpkgs> for the full package set — whichever channel is active locally
# or set by the CI workflow (nixos-25.11). The chromium package files come from
# our sparse checkout, which fetch-nixpkgs pulls from the same channel.

let
  pkgs = import <nixpkgs> { };

  # Our sparse-checked-out + patched chromium package directory.
  chromiumDir = ./nixpkgs/pkgs/applications/networking/browsers/chromium;

in
  pkgs.callPackage chromiumDir { }
