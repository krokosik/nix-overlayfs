# DXVK as a file layer: its DLLs, and "native" overrides for them in the
# layer's registry (not WINEDLLOVERRIDES, so per-program exceptions under
# HKCU\Software\Wine\AppDefaults still apply; see lib/mkFileLayer.nix).
#
# `dxvk` is a directory with x64/ and x32/ subdirectories: nixpkgs' dxvk, or
# an unpacked release archive (see dxvkRelease in ../default.nix).
{
  lib,
  overlayfsLib,
  runtime,

  dxvk,
  packageName ? "dxvk",
}:
let
  dlls = [
    "d3d8"
    "d3d9"
    "d3d10core"
    "d3d11"
    "dxgi"
  ];
  src = lib.getBin dxvk;
  dir32 = if runtime.windowsArch == "wow64" then "syswow64" else "system32";
  filesFor =
    dir: sourceDir:
    lib.listToAttrs (
      map (dll: lib.nameValuePair "drive_c/windows/${dir}/${dll}.dll" "${src}/${sourceDir}/${dll}.dll") dlls
    );
in
overlayfsLib.mkFileLayer {
  pname = packageName;
  inherit (dxvk) version;
  files =
    filesFor dir32 "x32" // lib.optionalAttrs (runtime.windowsArch == "wow64") (filesFor "system32" "x64");
  registryDllOverrides = lib.genAttrs dlls (_: "native");
}
