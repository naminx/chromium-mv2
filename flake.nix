{
  description = "Custom Chromium Build with MV2 Support";

  outputs = { self }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: builtins.listToAttrs (map (system: { name = system; value = f system; }) supportedSystems);
    in
    {
      packages = forAllSystems (system: {
        default = import ./default.nix { inherit system; };
      });
    };
}
