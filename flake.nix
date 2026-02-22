{
  description = "Custom Chromium Build with MV2 Support";

  outputs = { self }: {
    packages.x86_64-linux.default = import ./default.nix { system = "x86_64-linux"; };
  };
}
