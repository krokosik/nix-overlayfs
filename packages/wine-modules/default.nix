{
  lib,
  __splicedPackages,
  runtime,
  overlayfsLib,
}:

let
  pkgs = __splicedPackages;
  inherit (lib) makeExtensible;

  callPackageWithScope =
    scope: drv: args:
    lib.callPackageWith scope drv args;
  mkScope = scope: pkgs // scope;

  packages =
    self:
    let
      runtimeWithLayers = runtime // {
        baseEnvLayer = self.base-env;
        selectBaseEnvLayer =
          {
            hostIntegration ? true,
            managedRuntime ? "auto",
          }:
          if hostIntegration then
            if managedRuntime == "disabled" then
              self.base-env-no-managed-runtime
            else if managedRuntime == "external" then
              self.base-env-external-managed-runtime
            else
              self.base-env
          else if managedRuntime == "disabled" then
            self.base-env-headless
          else if managedRuntime == "external" then
            self.base-env-external-managed-runtime-no-host-integration
          else
            self.base-env-no-host-integration;
        autohotkeyLayer = self.autohotkey;
      };
      defaultScope = mkScope self;
      callPackage =
        drv: args: callPackageWithScope (defaultScope // { runtime = runtimeWithLayers; }) drv args;
    in
    rec {
      inherit overlayfsLib callPackage;
      runtime = runtimeWithLayers;

      base-env = callPackage ./wine-base-env { };
      base-env-headless = callPackage ./wine-base-env {
        hostIntegration = false;
        managedRuntime = "disabled";
      };
      base-env-no-host-integration = callPackage ./wine-base-env {
        hostIntegration = false;
      };
      base-env-no-managed-runtime = callPackage ./wine-base-env {
        managedRuntime = "disabled";
      };
      # Without Wine Mono, for prefixes that get .NET from a layer.
      base-env-external-managed-runtime = callPackage ./wine-base-env {
        managedRuntime = "external";
      };
      base-env-external-managed-runtime-no-host-integration = callPackage ./wine-base-env {
        hostIntegration = false;
        managedRuntime = "external";
      };
      autohotkey = callPackage ./autohotkey { };
      crypt32 = callPackage ./crypt32 { };
      dotnet-framework-4-8 = callPackage ./dotnet-framework-4-8 { };
      fonts = callPackage ./fonts { };
      gecko = callPackage ./wine-gecko { pkgs = pkgs; };
      dxvk = callPackage ./wine-dxvk { dxvk = pkgs.dxvk; };
      # DXVK from a release archive (dxvk-<version>.tar.gz, pinned by the
      # archive's hash): dxvkRelease { version = "2.7.1"; src = fetchurl { ... }; }
      dxvkRelease =
        { version, src }:
        callPackage ./wine-dxvk {
          dxvk = pkgs.stdenvNoCC.mkDerivation {
            pname = "dxvk";
            inherit version src;
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -r x32 x64 "$out"/
              runHook postInstall
            '';
          };
          packageName = "dxvk";
        };
      dxvk_2_6_2 = dxvkRelease {
        version = "2.6.2";
        src = pkgs.fetchurl {
          url = "https://github.com/doitsujin/dxvk/releases/download/v2.6.2/dxvk-2.6.2.tar.gz";
          # Unpacks to the tree the earlier fetchzip pin had (sha256 1vfw4amw...).
          hash = "sha256-F3YYdlVq/VVzbLiV0YT1ocVdQzUPGx47Ep+NKHBteZI=";
        };
      };
      vkd3d-proton = callPackage ./vkd3d-proton { };
      mfc42 = callPackage ./mfc42 { };
      mingw = callPackage ./mingw { };
      msvcp60 = callPackage ./msvcp60 { };
      msxml4 = callPackage ./msxml4 { };
      msxml6 = callPackage ./msxml6 { };
      vcrun2022 = callPackage ./vcrun2022 { };
      # WebView2 from a pinned installer (x64 Evergreen Standalone Installer
      # 154.0.4258.62), without winget-pkgs. For a package with
      # managedRuntime = "external":
      # webview2.override { managedRuntime = "external"; }
      # (Before, `webview2` was the winget-based module, now webview2-winget.)
      webview2 = callPackage ./webview2 { };
      # WebView2 from another installer, pinned by its hash:
      # webview2Release { version = "..."; src = fetchurl { ... }; }
      webview2Release =
        {
          version,
          src,
          architecture ? "x64",
          managedRuntime ? "auto",
        }:
        webview2.override {
          installerVersion = version;
          installer = src;
          installerArchitecture = architecture;
          inherit managedRuntime;
        };
      # WebView2 as winget-pkgs' manifest names it today: evaluating it
      # fetches microsoft/winget-pkgs and imports from a derivation. Prefer
      # webview2 or webview2Release.
      webview2-winget = callPackage ./webview2-winget { };
      win10 = callPackage ./win10 { };
      win11 = callPackage ./win11 { };
    };
in
makeExtensible packages
