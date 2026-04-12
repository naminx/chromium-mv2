{ system ? builtins.currentSystem, pkgsSrc ? null, ... }:

let
  nixpkgsSrc = if pkgsSrc != null then pkgsSrc else builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-25.11.tar.gz";

  pkgs = import nixpkgsSrc { inherit system; };

in
  pkgs.callPackage ./package.nix { }
