{
  pkgs,
  overlayfsLib,
}:
let
  basePackage = pkgs.stdenvNoCC.mkDerivation {
    pname = "registry-timeouts-base";
    version = "1.0.0";

    dontUnpack = true;

    installPhase = ''
      mkdir -p "$out"
    '';
  };

  fakeSession = {
    env = { };
    preCommands = "";
    postCommands = "";
    commands = {
      wine = "${pkgs.coreutils}/bin/false";
      wineserver = "${pkgs.coreutils}/bin/false";
    };
  };

  package = overlayfsLib.mkOverlayfsPackage {
    inherit basePackage;
    executableName = "registry-timeouts";
    executablePath = "/drive_c/windows/system32/notepad.exe";
    launchProgram = "${pkgs.coreutils}/bin/false";
    session = fakeSession;
    urlSchemes = [ "registry-timeout-test" ];
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "registry-timeouts-test";
  version = "1.0.0";

  dontUnpack = true;

  buildPhase = ''
    script="${package}/libexec/registry-timeouts-setupEnv.sh"

    # The host URL opener comes from the integration layer, not from a
    # registry write at launch; the hook functions stay for packages.
    grep -F 'nix_overlayfs_upsert_user_reg_section() {' "$script"
    grep -F 'nix_overlayfs_configure_host_browser() {' "$script"
    ! grep -F 'WineBrowser'"'"' <<EOF' "$script"
    grep -Fx '[Software\\Wine\\WineBrowser]' ${package.integrationLayer}/user.reg
    grep -F '"Browsers"="/nix/store/' ${package.integrationLayer}/user.reg

    ! grep -F ' reg add "HKCU\\Software\\Classes\\$nix_overlayfs_url_scheme"' "$script"
    ! grep -F " reg add 'HKCU\Software\Wine\WineBrowser'" "$script"

    grep -F 'Software\\Classes' ${../../lib/composeWindowsLayers.nix}
    grep -F 'Software\\Classes' ${../../lib/mkWindowsPackage.nix}
    grep -F 'timeout --foreground 30s' ${../../packages/wine-modules/wine-base-env/default.nix}
    grep -F 'timeout --foreground 30s' ${../../packages/wine-modules/wine-gecko/default.nix}
  '';

  installPhase = "touch $out";
}
