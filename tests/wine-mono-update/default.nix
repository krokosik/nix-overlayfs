{ pkgs, ... }:
let
  metadata = builtins.fromJSON (
    builtins.readFile ../../packages/wine-modules/wine-base-env/wine-mono.json
  );
  checkSelection =
    version: mono:
    let
      modules = pkgs.nix-overlayfs.moduleScopes.makeNativeModules {
        wine = pkgs.wineWow64Packages.unstableFull // {
          inherit version;
        };
        windowsArch = "wow64";
      };
      selected = modules.base-env.wine-mono;
    in
    if mono == null then
      selected == null
    else
      selected != null && selected.name == "wine-mono-${mono}-x86.msi";
in
assert pkgs.lib.all (version: checkSelection version metadata.versions.${version}) (
  builtins.attrNames metadata.versions
);
pkgs.runCommand "wine-mono-update-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  cp -r ${../../scripts} scripts
  mkdir -p tests/wine-mono-update
  cp ${./test_update.py} tests/wine-mono-update/test_update.py
  python3 -m unittest discover -s tests/wine-mono-update -v
  touch "$out"
''
