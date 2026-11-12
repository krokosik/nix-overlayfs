# Maintainer: Conroy Cheers <conroy@corncheese.org>
# Based on original work by Libor Štěpánek 2025
{
  pkgs,
  overlayfsLib,
}:
let
  newScope = extra: pkgs.lib.callPackageWith (pkgs // defaults // extra);
  defaults = {
    inherit overlayfsLib;
  };
in
pkgs.lib.makeScope newScope (
  self: with self; {
    scripts = callPackage ./scripts { };
    runtimeScripts = callPackage ./runtime { };
    dllOverrides = import ./dll-overrides.nix { inherit (pkgs) lib; };
    managedRuntime = import ./managed-runtime.nix { inherit (pkgs) lib; };
    launchRuntime = import ./launch-runtime.nix { inherit (pkgs) lib; };
    hostUrlOpener = callPackage ./host-url-opener.nix { };
    hostStartShim = callPackage ./host-start-shim.nix { };
    urlSchemeDiscoverers = callPackage ./url-scheme-discoverers.nix { };
    composeWindowsLayers = callPackage ./composeWindowsLayers.nix { };
    mkGraphicsBootstrap = callPackage ./mkGraphicsBootstrap.nix { };
    mkOverlayfsPackage = callPackage ./mkOverlayfsPackage.nix { };
    mkWindowsPackage = callPackage ./mkWindowsPackage.nix { };
    mkWinpkgsPackage = callPackage ./mkWinpkgsPackage.nix { };
    diffs = {
      system = ./diffs/system.json.diff;
      user = ./diffs/user.json.diff;
      dupes = builtins.filter (s: s != "") (
        pkgs.lib.splitString "\n" (builtins.readFile ./diffs/windows_duplicates)
      );
    };
  }
)
