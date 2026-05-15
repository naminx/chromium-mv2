{
  description = "Custom Chromium Build with MV2 Support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      packages.x86_64-linux.default = import ./default.nix {
        system = "x86_64-linux";
        pkgsSrc = nixpkgs;
      };

      # Run `nix develop` to get a shell with build tooling.
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [
          pkgs.bash
          pkgs.coreutils
          pkgs.hcloud
          # toolchain packager dependencies
          pkgs.git
          pkgs.p7zip
          pkgs.gh
          pkgs.qemu
          pkgs.util-linux  # mount/umount
          (pkgs.python3.withPackages (ps: [
            ps.py7zr
          ]))
        ];
        shellHook = ''
          echo "🐳 Build shell ready. Run: ./build-docker.sh <CHROMIUM_VERSION>"
        '';
      };
    };
}
