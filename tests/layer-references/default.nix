# An installation depends on its dependencies' layers, not on their
# launchers, so launcher-only changes do not rebuild dependent installations.
# Evaluation only: nothing here runs Wine.
{
  pkgs,
  overlayfsLib,
}:
let
  baseEnvLayer = pkgs.runCommand "layer-references-base-env" { } ''
    mkdir -p "$out/basePackage"
  '';

  # Enough of a runtime for mkWindowsPackage, without Wine.
  runtime = {
    toolsPackage = pkgs.coreutils;
    programFilesPath = "/drive_c/Program Files";
    selectBaseEnvLayer = _: baseEnvLayer;
    mkSession = _: {
      buildInputs = [ ];
      env = { };
      preCommands = "";
      postCommands = "";
      commands = {
        wine = "${pkgs.coreutils}/bin/true";
        wineserver = "${pkgs.coreutils}/bin/true";
      };
    };
  };

  dependency =
    launcherSettings:
    overlayfsLib.mkWindowsPackage (
      {
        inherit runtime;
        pname = "layer-references-dependency";
        version = "1.0.0";
        packageName = "layer-references-dependency";
        src = pkgs.emptyFile;
        unshareInstall = _: "true";
      }
      // launcherSettings
    );

  application =
    dependencyPackage:
    overlayfsLib.mkWindowsPackage {
      inherit runtime;
      pname = "layer-references-application";
      version = "1.0.0";
      packageName = "layer-references-application";
      src = pkgs.emptyFile;
      overlayDependencies = [ dependencyPackage ];
      unshareInstall = _: "true";
    };

  plain = dependency { };
  # Same installation, different launcher.
  relaunched = dependency {
    runtimeEnvVars.LAYER_REFERENCES_TEST = "changed";
    dllOverrides.d3d11 = "n";
    registerHostUrlHandlers = false;
  };
in
assert plain.drvPath != relaunched.drvPath;
assert plain.basePackage.drvPath == relaunched.basePackage.drvPath;
assert (application plain).basePackage.drvPath == (application relaunched).basePackage.drvPath;
pkgs.runCommand "layer-references-test" { } ''
  touch "$out"
''
