# managedRuntime = "external": no Wine Mono, .NET from a layer. Evaluation only.
{ pkgs, ... }:
let
  modulesFor =
    wine:
    pkgs.nix-overlayfs.moduleScopes.makeNativeModules {
      inherit wine;
      windowsArch = "wow64";
    };
  wineWith = attrs: pkgs.wineWow64Packages.unstableFull // attrs;

  modules = modulesFor (wineWith { version = "11.20"; });

  # A prefix that gets .NET from the dotnet-framework-4-8 layer has no Wine
  # Mono, and a package must not put that layer on a base with Wine Mono.
  # (A free stand-in for the unfree layer, which the checks cannot evaluate.)
  externalDotnetLayer = pkgs.runCommand "external-dotnet-layer" {
    passthru = {
      requiredManagedRuntime = "external";
      runtimeEnvVars = { };
    };
  } "mkdir -p $out/basePackage";
  dotnetUser =
    managedRuntime:
    modules.overlayfsLib.mkWindowsPackage {
      inherit (modules) runtime;
      inherit managedRuntime;
      pname = "dotnet-user";
      version = "1.0.0";
      packageName = "dotnet-user";
      src = pkgs.emptyFile;
      overlayDependencies = [ externalDotnetLayer ];
      unshareInstall = _: "true";
    };
  evaluates = package: (builtins.tryEval (builtins.deepSeq package.drvPath true)).success;
in
assert modules.base-env-external-managed-runtime.wine-mono == null;
assert modules.base-env-external-managed-runtime-no-host-integration.wine-mono == null;
assert modules.dotnet-framework-4-8.managedRuntime == "external";
assert modules.dotnet-framework-4-8.requiredManagedRuntime == "external";
assert evaluates (dotnetUser "external");
assert !(evaluates (dotnetUser "auto"));
pkgs.runCommand "managed-runtime-external" { } ''
  touch "$out"
''
