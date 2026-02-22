# Build customized Chromium locally or fetch remotely.
#
# Usage (local):
#   nix-build
#
# Usage (in NixOS configuration.nix):
#   chromium-custom = import (builtins.fetchTarball "https://github.com/naminx/chromium-mv2/archive/master.tar.gz") { };
#
# nixpkgs-pin.json is updated automatically by CI after each successful build
# to record the exact nixpkgs commit used, ensuring the derivation hash matches
# between CI and your local machine, allowing Cachix to serve the binary.

{ system ? builtins.currentSystem, ... }:

let
  pin = builtins.fromJSON (builtins.readFile ./nixpkgs-pin.json);

  nixpkgsSrc = builtins.fetchTarball {
    url    = "https://github.com/NixOS/nixpkgs/archive/${pin.rev}.tar.gz";
    sha256 = pin.sha256;
  };

  pkgs = import nixpkgsSrc { inherit system; };

  # Collect our local patches
  patchPaths = builtins.attrNames (builtins.readDir ./patches);
  validPatches = builtins.filter (n: builtins.match ".*\\.patch" n != null) patchPaths;
  formatPatch = name: "      \"${./patches + "/${name}"}\"";
  patchListStr = builtins.concatStringsSep "\n" (map formatPatch validPatches);

  # Dynamically copy Chromium package logic and inject our patches via IFD
  patchedChromiumDir = pkgs.runCommand "patched-chromium-dir" {
    nativeBuildInputs = [ pkgs.python3 ];
    PATCH_LIST = patchListStr;
  } ''
    cp -r ${nixpkgsSrc}/pkgs/applications/networking/browsers/chromium $out
    chmod -R +w $out

    python3 - $out/common.nix <<'PYEOF'
    import sys, os

    path = sys.argv[1]
    patch_list = os.environ.get('PATCH_LIST', "")

    with open(path) as f:
        content = f.read()

    start = content.index("    patches = [")
    end   = content.index("    ];\n", start)

    custom_block = (
        "    ] ++ [\n"
        "      # BEGIN custom patches\n"
        + patch_list + "\n"
        "      # END custom patches\n"
        "    ];\n"
    )

    new_content = content[:end] + custom_block + content[end + len("    ];\n"):]

    with open(path, 'w') as f:
        f.write(new_content)
    PYEOF
  '';

in
  pkgs.callPackage (import "${patchedChromiumDir}/default.nix") { }
