# Distribution builds of a Wine release (winum's "11.20-1") select the same
# Wine Mono as the release itself. Evaluation only.
{ pkgs, ... }:
let
  modulesFor =
    wine:
    pkgs.nix-overlayfs.moduleScopes.makeNativeModules {
      inherit wine;
      windowsArch = "wow64";
    };
  wineWith = attrs: pkgs.wineWow64Packages.unstableFull // attrs;

  release = modulesFor (wineWith { version = "11.20"; });
  buildSuffix = modulesFor (wineWith { version = "11.20-1"; });
  # A package naming its release, as winum's nix/wine.nix does.
  named = modulesFor (wineWith {
    version = "11.20-custom";
    wineVersion = "11.20";
  });
  proton = modulesFor (wineWith { version = "Proton8-26"; });

in
assert release.runtime.upstreamVersion == "11.20";
assert buildSuffix.runtime.upstreamVersion == "11.20";
assert buildSuffix.runtime.version == "11.20-1";
assert named.runtime.upstreamVersion == "11.20";
assert proton.runtime.upstreamVersion == "Proton8-26";
assert buildSuffix.base-env.wine-mono.name == release.base-env.wine-mono.name;
assert named.base-env.wine-mono.name == "wine-mono-11.3.0-x86.msi";
pkgs.runCommand "wine-release-versions" { } ''
  touch "$out"
''
