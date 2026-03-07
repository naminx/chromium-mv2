{
  description = "Custom Chromium Build with MV2 Support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    packages.x86_64-linux.default = import ./default.nix { 
      system = "x86_64-linux";
      pkgsSrc = nixpkgs;
    };
  };
}
