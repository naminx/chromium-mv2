{
  description = "Custom Chromium Build with MV2 Support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in
  {
    packages.x86_64-linux.default = import ./default.nix {
      system = "x86_64-linux";
      pkgsSrc = nixpkgs;
    };

    # Run `nix develop` to get a shell with podman for the Docker build workflow.
    devShells.x86_64-linux.default = pkgs.mkShell {
      packages = [
        pkgs.podman
        pkgs.bash
        pkgs.coreutils
      ];
      shellHook = ''
        echo "🐳 Podman $(podman --version) ready."
        echo "   Run: ./build-docker.sh <CHROMIUM_VERSION>"
      '';
    };
  };
}
