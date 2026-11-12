{
  lib,
  symlinkJoin,
}:
{
  wine,
  windowsArch ? "wow64",
  id ? "native-${windowsArch}",
  backend ? "wine-native",
  preferredInstallerArchitecture ? if windowsArch == "win32" then "x86" else "x64",
  capabilities ? { },
  extraEnv ? { },
  extraPreCommands ? "",
  extraPostCommands ? "",
  extraCommands ? { },
}:
let
  runtimeVersion = if (wine ? version) then wine.version else lib.getVersion wine;
  # The upstream Wine release, for tables keyed on Wine releases (Wine Mono,
  # Gecko, workarounds). Distributions add a build number ("11.20-1" for
  # winum's first build of Wine 11.20); a package may name its release in
  # passthru.wineVersion, otherwise a numeric "-N" suffix is dropped.
  # Names such as "Proton8-26" are kept as they are.
  upstreamVersion =
    let
      release = builtins.match "([0-9]+[.][0-9]+([.][0-9]+)?)-[0-9]+" runtimeVersion;
    in
    wine.wineVersion or (if release == null then runtimeVersion else builtins.head release);
  runtimeCapabilities = capabilities;

  toolsPackage = symlinkJoin {
    pname = "${if (wine ? pname) then wine.pname else "wine"}-${windowsArch}-tools";
    version = runtimeVersion;
    paths = [ wine ];
    meta = (wine.meta or { }) // {
      mainProgram = "wine";
    };
  };

  commands =
    let
      wineCommand = "${toolsPackage}/bin/wine";
    in
    {
      wine = wineCommand;
      wine64 = if windowsArch == "win32" then null else wineCommand;
      wineserver = "${toolsPackage}/bin/wineserver";
      wineboot = "${toolsPackage}/bin/wineboot";
      winecfg = "${toolsPackage}/bin/winecfg";
    }
    // extraCommands;
in
rec {
  inherit
    id
    toolsPackage
    windowsArch
    preferredInstallerArchitecture
    backend
    upstreamVersion
    ;
  version = runtimeVersion;
  programFiles32Path = "/drive_c/Program Files" + (if windowsArch == "win32" then "" else " (x86)");
  programFilesPath = "/drive_c/Program Files";
  baseEnvLayer = null;
  autohotkeyLayer = null;
  capabilities = {
    canRunWin64 = windowsArch != "win32";
    requires4kPages = false;
    requiresGuestRootfs = false;
  } // runtimeCapabilities;

  mkSession =
    {
      phase ? "launch",
      sessionRoot,
      overlayRoot,
      homeDir,
    }:
    let
      privateRuntimeEnv =
        lib.optionalAttrs (phase != "launch") {
          XDG_RUNTIME_DIR = ''"${sessionRoot}/xdg-runtime"'';
        };
      privateRuntimePreCommands =
        lib.optionalString (phase != "launch") ''
          mkdir -p "${sessionRoot}/xdg-runtime"
          chmod 700 "${sessionRoot}/xdg-runtime"
        '';
    in
    {
      buildInputs = [ toolsPackage ];
      env = {
        HOME = ''"${homeDir}"'';
        WINEPREFIX = ''"${overlayRoot}"'';
        WINEARCH = lib.escapeShellArg windowsArch;
      } // privateRuntimeEnv // extraEnv;
      preCommands = ''
        mkdir -p "${sessionRoot}"
        ${privateRuntimePreCommands}
      '' + extraPreCommands;
      postCommands = extraPostCommands;
      inherit commands;
    };
}
