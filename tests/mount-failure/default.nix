# A launcher whose layers cannot be mounted stops before the application
# starts and leaves nothing of the session in the writable layer. The build
# sandbox has neither /dev/fuse nor a setuid fusermount3, so the mount fails.
{
  pkgs,
  overlayfsLib,
}:
let
  launch = pkgs.writeShellScript "mount-failure-launch" ''
    touch "$NIX_OVERLAYFS_TEST_STARTED"
  '';

  package = overlayfsLib.mkOverlayfsPackage {
    basePackage = pkgs.runCommand "mount-failure-base" {
      pname = "mount-failure-base";
      version = "1.0.0";
    } "mkdir -p $out/drive_c/windows/system32";
    executableName = "mount-failure";
    executablePath = "/drive_c/windows/system32/notepad.exe";
    launchProgram = "${launch}";
    namespaceMode = "direct";
  };
in
pkgs.runCommand "mount-failure-test" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -euo pipefail

  export HOME="$PWD/home"
  export XDG_RUNTIME_DIR="$PWD/run"
  export NIX_OVERLAYFS_TEST_STARTED="$PWD/started"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR"

  status=0
  ${package}/bin/mount-failure < /dev/null > launch.log 2>&1 || status=$?
  cat launch.log

  test "$status" -eq 1
  grep -F 'error: nix-overlayfs: could not mount the layers of mount-failure-base' launch.log
  grep -F 'needs a setuid fusermount3' launch.log
  test ! -e "$NIX_OVERLAYFS_TEST_STARTED"

  upper="$HOME/.local/share/mount-failure-base"
  test -d "$upper/drive_c/windows/system32"
  test ! -e "$upper/drive_c/windows/system32/start.exe"
  test ! -e "$upper/drive_c/windows/syswow64/start.exe"
  test ! -e "$upper/.nix-overlayfs/session.pid"
  # The session directory is gone.
  test -z "$(ls -A "$HOME/.cache/nix-overlayfs/tmp" 2>/dev/null)"

  touch "$out"
''
