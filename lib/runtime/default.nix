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
  gawk,
  gnugrep,
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

    # No runtime inputs: the browser it starts gets the caller's PATH.
    hostBrowserBroker = writeShellApplication {
      name = "nix-overlayfs-host-browser-broker";
      runtimeInputs = [ ];
      text = builtins.readFile ./host-browser-broker.sh;
    };
  };
in
self
