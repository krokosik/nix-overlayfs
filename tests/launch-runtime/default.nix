# Installing with one Wine and launching with another build of the same Wine
# release rebuilds only the launcher. Evaluation only: nothing runs Wine.
{
  pkgs,
  overlayfsLib,
}:
let
  baseEnvLayer = pkgs.runCommand "launch-runtime-base-env" { } ''
    mkdir -p "$out/basePackage"
  '';

  # Enough of a runtime for mkWindowsPackage; `tools` stands in for a Wine.
  fakeRuntime =
    {
      name,
      version,
      upstreamVersion,
      windowsArch ? "wow64",
    }:
    let
      tools = pkgs.runCommand "launch-runtime-${name}" { } ''
        mkdir -p "$out/bin"
      '';
    in
    {
      inherit version upstreamVersion windowsArch;
      toolsPackage = tools;
      programFilesPath = "/drive_c/Program Files";
      selectBaseEnvLayer = _: baseEnvLayer;
      mkSession = _: {
        buildInputs = [ ];
        env = { };
        preCommands = "";
        postCommands = "";
        commands = {
          wine = "${tools}/bin/wine";
          wineserver = "${tools}/bin/wineserver";
        };
      };
    };

  release = fakeRuntime {
    name = "release";
    version = "11.20-1";
    upstreamVersion = "11.20";
  };
  candidate = fakeRuntime {
    name = "candidate";
    version = "11.20-1";
    upstreamVersion = "11.20";
  };
  newer = fakeRuntime {
    name = "newer";
    version = "11.21-1";
    upstreamVersion = "11.21";
  };
  # Same release, but declared to change the prefix (e.g. a wine.inf patch).
  prefixChanging =
    fakeRuntime {
      name = "prefix-changing";
      version = "11.20-1";
      upstreamVersion = "11.20";
    }
    // {
      prefixCompatibility = "11.20+changed-wine-inf";
    };
  win32 = fakeRuntime {
    name = "win32";
    version = "11.20-1";
    upstreamVersion = "11.20";
    windowsArch = "win32";
  };

  package =
    args:
    overlayfsLib.mkWindowsPackage (
      {
        runtime = release;
        pname = "launch-runtime-application";
        version = "1.0.0";
        packageName = "launch-runtime-application";
        executableName = "launch-runtime-application";
        executablePath = "/drive_c/app.exe";
        src = pkgs.emptyFile;
        unshareInstall = _: "true";
      }
      // args
    );

  plain = package { };
  patched = package { launchRuntime = candidate; };
  composed =
    launchRuntime:
    overlayfsLib.composeWindowsLayers {
      runtime = release;
      inherit launchRuntime;
      packageName = "launch-runtime-composed";
      executableName = "launch-runtime-composed";
      executablePath = "/drive_c/app.exe";
      baseLayer = {
        inherit (plain) basePackage;
        overlayDependencies = [ ];
        runtimeEnvVars = { };
      };
    };
  evaluates = drv: (builtins.tryEval (builtins.deepSeq drv.drvPath true)).success;
in
# The installation is the same; only the launcher differs.
assert plain.basePackage.drvPath == patched.basePackage.drvPath;
assert plain.drvPath != patched.drvPath;
assert patched.launchProgram == "${candidate.toolsPackage}/bin/wine";
assert plain.launchProgram == "${release.toolsPackage}/bin/wine";
assert patched.launchRuntime == candidate && patched.runtime == release;
assert (composed candidate).launchProgram == "${candidate.toolsPackage}/bin/wine";
# Another Wine release or architecture is refused.
assert !(evaluates (package { launchRuntime = newer; }));
assert !(evaluates (package { launchRuntime = win32; }));
assert !(evaluates (package { launchRuntime = prefixChanging; }));
assert !(evaluates (composed newer));
pkgs.runCommand "launch-runtime-test" { } ''
  touch "$out"
''
