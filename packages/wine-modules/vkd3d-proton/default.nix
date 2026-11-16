# vkd3d-proton (Direct3D 12 on Vulkan) as a file layer: d3d12.dll and
# d3d12core.dll, and "native" overrides for them in the layer's registry.
# nixpkgs does not package vkd3d-proton, so this takes a release archive.
#
#   modules.vkd3d-proton.override {
#     archive = fetchurl { url = ".../vkd3d-proton-<v>.tar.zst"; hash = "..."; };
#     archiveVersion = "<v>";
#   }
#
# (Not `src`/`version`: callPackage would fill those from nixpkgs.)
#
# Any archive with the upstream layout works (x64/ and x86/, optionally
# below one top-level directory), for example a patched build.
{
  lib,
  stdenvNoCC,
  fetchurl,
  zstd,
  overlayfsLib,
  runtime,

  archiveVersion ? "3.0.1",
  archive ? fetchurl {
    url = "https://github.com/HansKristian-Work/vkd3d-proton/releases/download/v3.0.1/vkd3d-proton-3.0.1.tar.zst";
    hash = "sha256-PPIxVSKvXkNgXvbTxB2tkThwQL+XGZk08/erdsqqLww=";
  },
  packageName ? "vkd3d-proton",
}:
let
  dlls = [
    "d3d12"
    "d3d12core"
  ];
  unpacked = stdenvNoCC.mkDerivation {
    pname = "${packageName}-dlls";
    version = archiveVersion;
    src = archive;
    nativeBuildInputs = [ zstd ];
    dontConfigure = true;
    dontBuild = true;
    # The archive's top-level directory (if any) holds x64/ and x86/.
    sourceRoot = ".";
    installPhase = ''
      runHook preInstall
      root=$(dirname "$(find . -path '*/x64/d3d12.dll' -print -quit)")/..
      test -f "$root/x64/d3d12.dll" && test -f "$root/x86/d3d12.dll"
      mkdir -p "$out"
      cp -r "$root/x64" "$root/x86" "$out/"
      runHook postInstall
    '';
  };
  dir32 = if runtime.windowsArch == "wow64" then "syswow64" else "system32";
  filesFor =
    dir: sourceDir:
    lib.listToAttrs (
      map (
        dll: lib.nameValuePair "drive_c/windows/${dir}/${dll}.dll" "${unpacked}/${sourceDir}/${dll}.dll"
      ) dlls
    );
in
overlayfsLib.mkFileLayer {
  pname = packageName;
  version = archiveVersion;
  files =
    filesFor dir32 "x86" // lib.optionalAttrs (runtime.windowsArch == "wow64") (filesFor "system32" "x64");
  registryDllOverrides = lib.genAttrs dlls (_: "native");
  passthru = { inherit unpacked; };
}
