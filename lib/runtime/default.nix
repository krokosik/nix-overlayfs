# Small runtime helpers called by the generated launcher scripts. Each one is a
# standalone, shellchecked program so it can be tested without mounting a
# prefix.
{
  writeShellApplication,
  attr,
  coreutils,
  desktop-file-utils,
  diffutils,
  findutils,
  fuse3,
  gawk,
  gnugrep,
  gnused,
  scripts,
  util-linux,
  xdg-utils,
}:
let
  self = {
    guardPrefixUpdates = writeShellApplication {
      name = "nix-overlayfs-guard-prefix-updates";
      runtimeInputs = [ coreutils ];
      text = builtins.readFile ./guard-prefix-updates.sh;
    };

    checkShadowed = writeShellApplication {
      name = "nix-overlayfs-check-shadowed";
      runtimeInputs = [
        attr
        coreutils
        diffutils
        findutils
      ];
      text = builtins.readFile ./check-shadowed.sh;
    };

    sessions = writeShellApplication {
      name = "nix-overlayfs-sessions";
      runtimeInputs = [
        coreutils
        gawk
        gnugrep
        util-linux
      ];
      text = builtins.readFile ./sessions.sh;
    };

    forgetDesktopEntry = writeShellApplication {
      name = "nix-overlayfs-forget-desktop-entry";
      runtimeInputs = [
        coreutils
        diffutils
        gawk
        gnugrep
      ];
      text = builtins.readFile ./forget-desktop-entry.sh;
    };

    urlHandlers = writeShellApplication {
      name = "nix-overlayfs-url-handlers";
      runtimeInputs = [
        self.forgetDesktopEntry
        coreutils
        desktop-file-utils
        gawk
        gnugrep
        xdg-utils
      ];
      text = builtins.readFile ./url-handlers.sh;
    };

    registry = writeShellApplication {
      name = "nix-overlayfs-registry";
      runtimeInputs = [
        coreutils
        diffutils
        gawk
        scripts.mergeWineRegistries
      ];
      text = builtins.readFile ./registry.sh;
    };

    upperLayer = writeShellApplication {
      name = "nix-overlayfs-upper-layer";
      runtimeInputs = [
        coreutils
        diffutils
        findutils
      ];
      text = builtins.readFile ./upper-layer.sh;
    };

    namespace = writeShellApplication {
      name = "nix-overlayfs-namespace";
      runtimeInputs = [
        coreutils
        fuse3
        gnugrep
        gnused
        util-linux
      ];
      text = builtins.readFile ./namespace.sh;
    };

    # No runtime inputs: the browser it starts gets the caller's PATH.
    hostBrowserBroker = writeShellApplication {
      name = "nix-overlayfs-host-browser-broker";
      runtimeInputs = [ ];
      text = builtins.readFile ./host-browser-broker.sh;
    };
  };
in
self
