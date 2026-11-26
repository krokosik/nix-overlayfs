{
  pkgs,
  overlayfsLib,
}:
# Captured layers hold only their own registry changes, so a layer above
# does not mask what a layer below changed. Built with Wine: the base
# environment has HKCU\Control Panel\Desktop FontSmoothingType=1; "lower"
# sets it to 2 and deletes FontSmoothingGamma; "higher" is built on the base
# environment only and touches neither. Merged base, lower, higher (as a
# launcher of a package using both orders them), the lower layer's changes
# hold.
let
  lib = pkgs.lib;
  runtime = pkgs.nix-overlayfs.moduleScopes.nativeModules.runtime;
  layerRoot =
    dependency:
    if dependency ? basePackage && lib.isDerivation dependency.basePackage then
      "${dependency.basePackage}"
    else
      "${dependency}/basePackage";
  mkLayer =
    name: commands:
    overlayfsLib.mkWindowsPackage {
      inherit runtime;
      pname = "layer-registry-delta-${name}";
      version = "1";
      src = pkgs.writeText "layer-registry-delta-noop.txt" "";
      packageName = "layer-registry-delta-${name}";
      buildNamespaceMode = "direct";
      unshareInstall =
        { session, ... }:
        ''
          wine=${session.commands.wine}
          ${commands}
          ${session.commands.wineserver} --wait
        '';
    };
  lower = mkLayer "lower" ''
    "$wine" reg add 'HKCU\Control Panel\Desktop' /v FontSmoothingType /t REG_DWORD /d 2 /f
    "$wine" reg delete 'HKCU\Control Panel\Desktop' /v FontSmoothingGamma /f
  '';
  higher = mkLayer "higher" ''
    "$wine" reg add 'HKCU\Software\LayerRegistryDelta' /v Higher /t REG_SZ /d 1 /f
  '';
  base = layerRoot (builtins.head lower.overlayDependencies);
  registry = "${overlayfsLib.runtimeScripts.registry}/bin/nix-overlayfs-registry";
in
pkgs.runCommand "layer-registry-delta-test"
  {
    nativeBuildInputs = [ pkgs.gnugrep ];
  }
  ''
    set -euo pipefail
    base=${base}
    lower=${lower.basePackage}
    higher=${higher.basePackage}

    # The base environment has the value the test is about.
    grep -Fx '"FontSmoothingType"=dword:00000001' "$base/user.reg"
    grep -Fx '"FontSmoothingGamma"=dword:00000000' "$base/user.reg"

    # Each layer holds its own changes only.
    grep -Fx '"FontSmoothingType"=dword:00000002' "$lower/user.reg"
    grep -Fx '"FontSmoothingGamma"=-' "$lower/user.reg"
    grep -Fx '"Higher"="1"' "$higher/user.reg"
    ! grep -F 'FontSmoothing' "$higher/user.reg"
    test "$(wc -c < "$higher/user.reg")" -lt 4096
    # Keys of the dependencies that Wine does not write (subkeys, no
    # values) are not taken for deleted.
    ! grep -F '[-' "$higher/system.reg"

    # Composed at launch, lowest priority first.
    mkdir app state tmp
    ${registry} merge "$PWD/app" state/registry-sources tmp/registry-sources \
      "$base" "$lower" "$higher" "$PWD/app"
    grep -Fx '"FontSmoothingType"=dword:00000002' app/user.reg
    ! grep -F '"FontSmoothingGamma"' app/user.reg
    grep -Fx '"Higher"="1"' app/user.reg
    # Everything else of the base environment is there.
    grep -Fx '"FontSmoothingOrientation"=dword:00000001' app/user.reg

    touch "$out"
  ''
