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
{
  lib,
  fetchurl,
  coreutils,
  gnugrep,
  runtime,
  overlayfsLib,
}:
let
  dotnet40 = fetchurl {
    url = "https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe";
    sha256 = "65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f";
    meta.license = lib.licenses.unfree;
  };
  dotnet48 = fetchurl {
    url = "https://download.visualstudio.microsoft.com/download/pr/2d6bb6b2-226a-4baa-bdec-798822606ff1/8494001c276a4b96804cde7829c04d7f/ndp48-x86-x64-allos-enu.exe";
    sha256 = "68c9986a8dcc0214d909aa1f31bee9fb5461bb839edca996a75b08ddffc1483f";
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
