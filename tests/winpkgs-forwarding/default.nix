# mkWinpkgsPackage passes the mkWindowsPackage options it does not use itself
# on to mkWindowsPackage. Evaluation only, and only attributes that do not
# need the winget manifest (no winget-pkgs fetch).
{ pkgs, ... }:
let
  modules = pkgs.nix-overlayfs.moduleScopes.makeNativeModules {
    wine = pkgs.wineWow64Packages.unstableFull;
    windowsArch = "wow64";
  };
  winpkgs =
    args:
    modules.overlayfsLib.mkWinpkgsPackage (
      {
        inherit (modules) runtime;
        packageName = "Example/Example";
      }
      // args
    );
  baseOf = package: builtins.head package.overlayDependencies;

  external = winpkgs { managedRuntime = "external"; };
  headless = winpkgs {
    hostIntegration = false;
    managedRuntime = "disabled";
    namespaceMode = "direct";
    stateMode = "ephemeral";
  };
  default = winpkgs { };
in
assert external.managedRuntime == "external";
assert external.requiredManagedRuntime == "external";
assert baseOf external == modules.base-env-external-managed-runtime;
assert headless.hostIntegration == false;
assert headless.managedRuntime == "disabled";
assert headless.namespaceMode == "direct";
assert headless.stateMode == "ephemeral";
assert baseOf headless == modules.base-env-headless;
assert default.managedRuntime == "auto";
assert baseOf default == modules.base-env;
pkgs.runCommand "winpkgs-forwarding" { } ''
  touch "$out"
''
