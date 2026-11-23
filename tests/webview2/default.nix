# The WebView2 layer (`webview2`, pinned installer): its base environment
# follows managedRuntime, the installer is the pinned one (or
# webview2Release's), and it evaluates without winget-pkgs. Evaluation only;
# installing WebView2 needs the 180 MB installer.
#
# Run with --option allow-import-from-derivation false to check that nothing
# here reads a build result during evaluation (`webview2-winget` does; only
# attributes that need no manifest are read from it here).
{ pkgs, ... }:
let
  inherit (pkgs) lib;
  modulesOf =
    pkgs': windowsArch:
    pkgs'.nix-overlayfs.moduleScopes.makeNativeModules {
      wine = pkgs'.wineWow64Packages.unstableFull;
      inherit windowsArch;
    };
  modules = modulesOf pkgs "wow64";
  # The layer is unfree; its derivation only evaluates with unfree allowed.
  unfreePkgs = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (pkgs) overlays;
    config.allowUnfree = true;
  };
  unfreeModules = modulesOf unfreePkgs "wow64";
  win32Modules = modulesOf unfreePkgs "win32";

  baseOf = package: builtins.head package.overlayDependencies;
  evaluates = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  drvEvaluates = package: evaluates package.drvPath;

  pinned = modules.webview2;
  external = modules.webview2.override { managedRuntime = "external"; };
  release = modules.webview2Release {
    version = "1.2.3.4";
    src = pkgs.emptyFile;
    managedRuntime = "external";
  };

  consumer =
    modules': managedRuntime: layer:
    modules'.overlayfsLib.mkWindowsPackage {
      inherit (modules') runtime;
      inherit managedRuntime;
      pname = "webview2-consumer";
      version = "1.0.0";
      packageName = "webview2-consumer";
      src = pkgs.emptyFile;
      overlayDependencies = [ layer ];
      unshareInstall = _: "true";
    };

  unfreeExternal = unfreeModules.webview2.override { managedRuntime = "external"; };
  installScript = unfreeExternal.basePackage.passthru.buildPhaseUnshareScript.text;
in
# Base environment and managed-runtime requirement follow managedRuntime.
# The winget-based module is still there and takes managedRuntime.
assert modules.webview2-winget.managedRuntime == "auto";
assert
  (modules.webview2-winget.override { managedRuntime = "external"; }).requiredManagedRuntime
  == "external";
assert pinned.managedRuntime == "auto";
assert baseOf pinned == modules.base-env;
assert pinned.requiredManagedRuntime == null;
assert external.managedRuntime == "external";
assert external.requiredManagedRuntime == "external";
assert baseOf external == modules.base-env-external-managed-runtime;
# The pinned installer, unfree.
assert pinned.webview2Version == "154.0.4258.62";
assert pinned.installerArchitecture == "x64";
assert lib.hasSuffix "MicrosoftEdgeWebView2RuntimeInstallerX64.exe" pinned.installer.name;
assert pinned.meta.license == lib.licenses.unfree;
assert !(drvEvaluates pinned);
# webview2Release takes another installer.
assert release.webview2Version == "1.2.3.4";
assert release.installer == pkgs.emptyFile;
assert baseOf release == modules.base-env-external-managed-runtime;
# An x64 installer does not fit a 32-bit runtime.
assert !(drvEvaluates win32Modules.webview2);
assert drvEvaluates (
  win32Modules.webview2Release {
    version = "1.2.3.4";
    src = pkgs.emptyFile;
    architecture = "x86";
  }
);
# With unfree allowed, the layers and packages using them evaluate.
assert drvEvaluates unfreeModules.webview2;
assert drvEvaluates unfreeExternal;
assert drvEvaluates unfreeExternal.basePackage;
assert drvEvaluates (consumer unfreeModules "external" unfreeExternal);
assert drvEvaluates (consumer unfreeModules "auto" unfreeModules.webview2);
# A layer built on the external base fits only an external package.
assert !(drvEvaluates (consumer unfreeModules "auto" unfreeExternal));
# The install runs the pinned installer and checks its result.
assert lib.hasInfix "/silent /install" installScript;
assert lib.hasInfix "msedgewebview2.exe" installScript;
assert lib.hasInfix "--wait" installScript;
pkgs.runCommand "webview2" { } ''
  touch "$out"
''
