# The DXVK and vkd3d-proton modules as file layers: real release archives,
# both Windows architectures of a wow64 runtime, overrides in the registry.
{ pkgs, overlayfsLib, ... }:
let
  modules = pkgs.nix-overlayfs.moduleScopes.makeNativeModules {
    wine = pkgs.wineWow64Packages.unstableFull;
    windowsArch = "wow64";
  };
  inherit (modules) dxvk_2_6_2 vkd3d-proton;
in
# Built without Wine, and nothing for WINEDLLOVERRIDES.
assert overlayfsLib.dllOverrides.fromLayer dxvk_2_6_2 == { };
assert overlayfsLib.dllOverrides.fromLayer vkd3d-proton == { };
pkgs.runCommand "graphics-layers-test" { nativeBuildInputs = [ pkgs.jq pkgs.file ]; } ''
  set -euo pipefail
  check() {
    local dll=$1 dir=$2 machine=$3
    file "$dir/$dll.dll" | grep -q "$machine"
  }
  d=${dxvk_2_6_2}/basePackage/drive_c/windows
  for dll in d3d8 d3d9 d3d10core d3d11 dxgi; do
    check $dll $d/system32 'PE32+'
    check $dll $d/syswow64 'PE32 '
  done
  jq -e '.keys["Software\\\\Wine\\\\DllOverrides"]["\"d3d11\""] == "\"native\""' ${dxvk_2_6_2}/basePackage/user.json

  v=${vkd3d-proton}/basePackage/drive_c/windows
  for dll in d3d12 d3d12core; do
    check $dll $v/system32 'PE32+'
    check $dll $v/syswow64 'PE32 '
  done
  jq -e '.keys["Software\\\\Wine\\\\DllOverrides"] == {"\"d3d12\"": "\"native\"", "\"d3d12core\"": "\"native\""}' ${vkd3d-proton}/basePackage/user.json
  touch $out
''
