# Microsoft .NET Framework 4.8 as a layer, replacing Wine Mono for programs
# that need the real .NET Framework (e.g. Autodesk Inventor's Import CAD
# Property Mapping and 3D PDF). Earlier version: the winget DeveloperPack
# through mkWinpkgsPackage (Conroy Cheers, based on work by Libor Štěpánek),
# which installed nothing under Wine for the reasons below.
#
# The plain redistributable does not install under Wine; the order matters
# (tested on a fresh Wine 11.20 prefix, 2026-11-11):
# - Wine's own .NET answers go first: Wine Mono, Wine's mscoree.dll and the
#   "NDP\v4" registry key that reports 4.8 as installed - otherwise the 4.8
#   setup exits at once ("already installed").
# - The setups run with the prefix set to Windows 7: on Windows 10, 4.8 is
#   part of the OS and the redistributable refuses to install.
# - .NET 4.0 first: the 4.8 setup on Windows 7 does not install the
#   mscoree.dll shim, 4.0 does.
# - The prefix goes back to Windows 10; mscoree=native is exported to every
#   program launched on top of this layer (dllOverrides).
# - mscoree.dll has a Wine builtin namesake, so the layer keeps it explicitly
#   (extraPathsToInclude); without it the composed prefix falls back to Wine's
#   mscoree and .NET Framework programs fail to start.
{
  lib,
  fetchurl,
  coreutils,
  gnugrep,
  runtime,
  overlayfsLib,
}:
let
  # The same URL and SHA-256 as winetricks' dotnet40 verb.
  dotnet40 = fetchurl {
    url = "https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe";
    sha256 = "65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f";
    meta.license = lib.licenses.unfree;
  };
  # The offline installer Microsoft's .NET Framework 4.8 download page links
  # to (go.microsoft.com/fwlink/?linkid=2088631, resolved on 2026-11-13). The
  # SHA-256 was computed from that download on 2026-11-13; its Authenticode
  # signature is Microsoft Corporation's and its signed digest matches the
  # file (osslsigncode; the chain is not checkable against the Mozilla CA
  # bundle, which lacks Microsoft's code-signing root). winetricks' dotnet48
  # verb uses an older build of the same installer from another URL (signed
  # 2019, SHA-256 95889d6d...), so the two hashes differ.
  dotnet48 = fetchurl {
    url = "https://download.microsoft.com/download/f/3/a/f3a6af84-da23-40a5-8d1c-49cc10c8e76f/NDP48-x86-x64-AllOS-ENU.exe";
    sha256 = "0a3a390c47e639d0f7fc65b21195fee6b7f65b066f80f70c60fab191d14b7e40";
    meta.license = lib.licenses.unfree;
  };
  has64 = runtime.windowsArch != "win32";
in
(overlayfsLib.mkWindowsPackage {
  inherit runtime;
  pname = "dotnet-framework";
  version = "4.8";
  packageName = "dotnet-framework-4-8";
  src = dotnet48;
  dllOverrides = {
    mscoree = "native";
  };
  extraPathsToInclude = [
    "windows/system32/mscoree.dll"
  ]
  ++ lib.optional has64 "windows/syswow64/mscoree.dll";
  unshareInstall =
    { session, ... }:
    ''
      set -euo pipefail
      wine=${session.commands.wine}
      wineserver=${session.commands.wineserver}
      windir="$WINEPREFIX/drive_c/windows"
      settle() { ${coreutils}/bin/timeout 300 $wineserver --wait || $wineserver -k; }

      rm -rf "$windir/mono"
      rm -f "$windir/system32/mscoree.dll" "$windir/syswow64/mscoree.dll"
      for key in 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4' \
                 'HKLM\Software\Wow6432Node\Microsoft\NET Framework Setup\NDP\v4'; do
        $wine reg delete "$key" /f || true
      done
      $wine reg add 'HKCU\Software\Wine\DllOverrides' /v mscoree /t REG_SZ /d native /f
      $wine winecfg /v win7
      settle

      # The setups' exit codes are not reliable under Wine; the checks below are.
      $wine ${dotnet40} /q /norestart || true
      settle
      $wine "$src" /q /norestart || true
      settle

      $wine winecfg /v win10
      settle

      release=$($wine reg query 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full' /v Release \
        | ${gnugrep}/bin/grep -o '0x[0-9a-fA-F]*' || true)
      echo ".NET Framework Release: $release"
      test -n "$release" && test "$((release))" -ge 528040
      for dir in system32 ${lib.optionalString has64 "syswow64"}; do
        test -s "$windir/$dir/mscoree.dll"
        # Microsoft's shim, not Wine's builtin placeholder
        ! ${gnugrep}/bin/grep -q WINEDATADIR "$windir/$dir/mscoree.dll"
      done
      test -s "$windir/Microsoft.NET/Framework/v4.0.30319/clr.dll"
      ${lib.optionalString has64 ''test -s "$windir/Microsoft.NET/Framework64/v4.0.30319/clr.dll"''}
    '';
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      license = lib.licenses.unfree;
    };
  })
