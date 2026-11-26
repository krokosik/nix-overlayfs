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

    # The "disable" marker comes from the launcher's integration layer; the
    # writable layer must not hide it, so a timestamp or marker there (from
    # an earlier update, or from launchers that predate the integration layer) is
    # removed.
    integration="${package.integrationLayer}"
    test "$(cat "$integration/.update-timestamp")" = disable
    mkdir -p base missing numeric disabled
    printf '7\n' > base/.update-timestamp
    ${guard} missing "$integration" "$PWD/base"
    test ! -e missing/.update-timestamp
    printf '1\n' > numeric/.update-timestamp
    ${guard} numeric "$integration" "$PWD/base"
    test ! -e numeric/.update-timestamp
    printf 'disable\n' > disabled/.update-timestamp
    ${guard} disabled "$integration" "$PWD/base"
    test ! -e disabled/.update-timestamp

    # A whiteout of the marker would hide it as well: the .wh. file form is
    # removed (the 0/0 character device form is tested in runtime-state-vm,
    # since mknod needs privileges).
    mkdir whiteout
    touch whiteout/.wh..update-timestamp
    ${guard} whiteout "$integration" "$PWD/base"
    test ! -e whiteout/.wh..update-timestamp
    ln -s /nowhere whiteout/.wh..update-timestamp
    NIX_OVERLAYFS_WINE_PREFIX_UPDATES=1 ${guard} whiteout "$integration" "$PWD/base"
    test ! -L whiteout/.wh..update-timestamp
    test "$(cat whiteout/.update-timestamp)" = 7
    # An opaque writable root cannot be repaired; it is reported.
    mkdir opaque
    touch opaque/.wh..wh..opq
    ${guard} opaque "$integration" 2> opaque.log
    grep -F 'is opaque' opaque.log

    # The opt-out gives the writable layer the timestamp of the highest
    # layer without the marker, so the Nix layers' timestamp applies again
    # (an empty one, as if missing, when no layer has one) ...
    NIX_OVERLAYFS_WINE_PREFIX_UPDATES=1 ${guard} numeric "$integration" "$PWD/base"
    test "$(cat numeric/.update-timestamp)" = 7
    NIX_OVERLAYFS_WINE_PREFIX_UPDATES=1 ${guard} new/appdir "$integration"
    test -f new/appdir/.update-timestamp -a ! -s new/appdir/.update-timestamp
    # ... and keeps one Wine wrote meanwhile.
    printf '42\n' > numeric/.update-timestamp
    NIX_OVERLAYFS_WINE_PREFIX_UPDATES=1 ${guard} numeric "$integration" "$PWD/base"
    test "$(cat numeric/.update-timestamp)" = 42
    # Back to the default: removed again.
    ${guard} numeric "$integration" "$PWD/base"
    test ! -e numeric/.update-timestamp

    ! ${guard} 2>/dev/null

    # The launcher guards the writable layer before it mounts the prefix.
    script="${package}/libexec/prefix-update-guard-setupEnv.sh"
    awk '
      /nix-overlayfs-guard-prefix-updates "\$appdir"/ && !guard { guard = NR }
      /\/bin\/fuse-overlayfs( |$)/ && !mount { mount = NR }
      /has no .update-timestamp that says disable/ && !check { check = NR }
      END {
        if (!guard || !mount || guard >= mount) {
          print "the prefix update guard must run before fuse-overlayfs mounts" > "/dev/stderr"
          exit 1
        }
        if (!check || check <= mount) {
          print "the launcher must check the mounted marker after mounting" > "/dev/stderr"
          exit 1
        }
      }
    ' "$script"

    touch "$out"
  ''
