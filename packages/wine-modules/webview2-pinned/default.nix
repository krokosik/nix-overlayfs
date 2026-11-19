# Microsoft Edge WebView2 Runtime from a pinned installer, without winget-pkgs.
#
# The `webview2` module resolves its installer from the microsoft/winget-pkgs
# repository at evaluation time (builtins.fetchGit plus import from
# derivation), so it always gets whatever version the manifest names and
# needs that repository to evaluate. This one runs the installer it is given:
# by default the x64 Evergreen Standalone Installer below, pinned by hash.
#
#   modules.webview2-pinned                      # on the default base (Wine Mono)
#   modules.webview2-pinned.override { managedRuntime = "external"; }
#   modules.webview2Release { version = "..."; src = fetchurl { ... }; }
#
# (Not `src`/`version` here: callPackage would fill those from nixpkgs.)
#
# The layer is the registry and file difference against the base environment
# it was installed on, so `managedRuntime` must be the one of the package that
# uses it; mkWindowsPackage and composeWindowsLayers refuse an "external"
# layer below a package that is not "external".
{
  lib,
  fetchurl,
  coreutils,
  findutils,
  runtime,
  overlayfsLib,

  installerVersion ? "154.0.4258.62",
  installer ? fetchurl {
    url = "https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/18c66e75-0385-4019-be3f-3f4a2bb867d5/MicrosoftEdgeWebView2RuntimeInstallerX64.exe";
    hash = "sha256-rCLs3BnFuIuH8/p1LADalUFlOo9cDF/Eo7K26+ZZH2k=";
    meta.license = lib.licenses.unfree;
  },
  # The Windows architecture of `installer`: x64, x86 or arm64.
  installerArchitecture ? "x64",
  managedRuntime ? "auto",
  packageName ? "webview2",
  # Seconds to wait for the installer's remaining Wine processes (the Edge
  # updater can stay behind) before they are killed.
  wineserverWaitTimeout ? 60,
}:
let
  # mk-runtime.nix sets preferredInstallerArchitecture (x86 for win32, else x64).
  runtimeArchitectures =
    runtime.preferredInstallerArchitectures or [ runtime.preferredInstallerArchitecture ];
  bounded = "${coreutils}/bin/timeout ${toString wineserverWaitTimeout}";
in
(overlayfsLib.mkWindowsPackage {
  inherit runtime managedRuntime packageName;
  pname = packageName;
  version = installerVersion;
  # Checked here, not around the whole package, so that .override can still
  # replace the installer of a scope whose runtime the default does not fit.
  src =
    lib.throwIfNot (builtins.elem installerArchitecture runtimeArchitectures)
      "${packageName}: the ${installerArchitecture} WebView2 installer does not fit this runtime (${lib.concatStringsSep ", " runtimeArchitectures}); pass one that does with webview2Release { version; src; architecture; }"
      installer;
  unshareInstall =
    { session, ... }:
    ''
      set -euo pipefail
      ${session.commands.wine} "$src" /silent /install
      ${bounded} ${session.commands.wineserver} --wait || {
        echo "warning: wineserver did not exit within ${toString wineserverWaitTimeout}s; killing remaining Wine processes" >&2
        ${session.commands.wineserver} -k || true
      }
      # Check the files, not only the installer's exit status. The x64
      # installer on wow64 installs Program Files (x86)/Microsoft/EdgeWebView/
      # Application/<version>/msedgewebview2.exe.
      webview=$(${findutils}/bin/find "$WINEPREFIX/drive_c" -path '*/EdgeWebView/Application/*/msedgewebview2.exe' -print -quit)
      if [ -z "$webview" ]; then
        echo "error: ${packageName}: msedgewebview2.exe was not installed" >&2
        exit 1
      fi
      echo "WebView2 installed: $webview"
      case "$webview" in
        */${lib.escapeShellArg installerVersion}/msedgewebview2.exe) ;;
        *)
          echo "error: ${packageName}: the installer did not install WebView2 ${installerVersion}" >&2
          exit 1
          ;;
      esac
    '';
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      description = "Microsoft Edge WebView2 Runtime ${installerVersion} (${installerArchitecture}) as a Wine layer";
      license = lib.licenses.unfree;
    };
    passthru = (old.passthru or { }) // {
      inherit installer installerArchitecture;
      webview2Version = installerVersion;
    };
  })
