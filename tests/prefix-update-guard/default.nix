{
  pkgs,
  overlayfsLib,
}:
let
  guard = "${overlayfsLib.runtimeScripts.guardPrefixUpdates}/bin/nix-overlayfs-guard-prefix-updates";

  package = overlayfsLib.mkOverlayfsPackage {
    basePackage = pkgs.runCommand "prefix-update-guard-base" {
      pname = "prefix-update-guard-base";
      version = "1.0.0";
    } "mkdir -p $out";
    executableName = "prefix-update-guard";
    executablePath = "/drive_c/windows/system32/notepad.exe";
    launchProgram = "${pkgs.coreutils}/bin/false";
  };
in
pkgs.runCommand "prefix-update-guard-test"
  {
    nativeBuildInputs = [
      pkgs.gawk
      pkgs.gnugrep
    ];
  }
  ''
    set -euo pipefail

    # No timestamp at all: Wine would run a full update, so the guard adds one.
    mkdir missing
    ${guard} missing
    test "$(cat missing/.update-timestamp)" = disable

    # A numeric timestamp left by an earlier update is replaced.
    mkdir numeric
    printf '1\n' > numeric/.update-timestamp
    ${guard} numeric
    test "$(cat numeric/.update-timestamp)" = disable

    # An existing marker is left alone (including a user's own "disable").
    mkdir disabled
    printf 'disable by hand\n' > disabled/.update-timestamp
    ${guard} disabled
    test "$(cat disabled/.update-timestamp)" = "disable by hand"

    # A missing writable layer is created.
    ${guard} new/appdir
    test "$(cat new/appdir/.update-timestamp)" = disable

    # The opt-out removes the marker so the Nix layers' timestamp applies.
    NIX_OVERLAYFS_WINE_PREFIX_UPDATES=1 ${guard} numeric
    test ! -e numeric/.update-timestamp
    printf '42\n' > numeric/.update-timestamp
    NIX_OVERLAYFS_WINE_PREFIX_UPDATES=1 ${guard} numeric
    test "$(cat numeric/.update-timestamp)" = 42

    ! ${guard} 2>/dev/null

    # The launcher guards the writable layer before it mounts the prefix.
    script="${package}/libexec/prefix-update-guard-setupEnv.sh"
    awk '
      /nix-overlayfs-guard-prefix-updates "\$appdir"/ && !guard { guard = NR }
      /\/bin\/fuse-overlayfs( |$)/ && !mount { mount = NR }
      END {
        if (!guard || !mount || guard >= mount) {
          print "the prefix update guard must run before fuse-overlayfs mounts" > "/dev/stderr"
          exit 1
        }
      }
    ' "$script"

    touch "$out"
  ''
