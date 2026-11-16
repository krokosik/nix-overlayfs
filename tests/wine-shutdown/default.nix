{
  pkgs,
  overlayfsLib,
}:
let
  shutdown = "${overlayfsLib.runtimeScripts.wineShutdown}/bin/nix-overlayfs-wine-shutdown";

  # Records its calls; with HANG set, --wait does not return.
  fakeWineserver = pkgs.writeShellScript "fake-wineserver" ''
    printf '%s %s %s\n' "$WINEPREFIX" "$WINEARCH" "$*" >> "$CALLS"
    if [ "$1" = --wait ] && [ -n "''${HANG:-}" ] && [ ! -e "$CALLS.killed" ]; then
      exec sleep 30
    fi
    if [ "$1" = -k ]; then
      touch "$CALLS.killed"
    fi
  '';

  fakeSession = {
    env = { };
    preCommands = "";
    postCommands = "";
    commands = {
      wine = "${pkgs.coreutils}/bin/false";
      wineserver = "${fakeWineserver}";
    };
  };

  package = overlayfsLib.mkOverlayfsPackage {
    basePackage = pkgs.runCommand "wine-shutdown-base" {
      pname = "wine-shutdown-base";
      version = "1.0.0";
    } "mkdir -p $out";
    executableName = "wine-shutdown";
    executablePath = "/drive_c/windows/system32/notepad.exe";
    launchProgram = "${pkgs.coreutils}/bin/false";
    session = fakeSession;
  };
in
pkgs.runCommand "wine-shutdown-test" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -euo pipefail
  export CALLS="$PWD/calls"
  mkdir overlay

  # The server finishes: one wait, for this prefix.
  WINEARCH=win64 ${shutdown} ${fakeWineserver} "$PWD/overlay" app 2> quick.log
  printf '%s\n' "$PWD/overlay win64 --wait" | diff -u - "$CALLS"
  test ! -s quick.log

  # It does not: killed after the timeout, then waited for again.
  rm "$CALLS"
  HANG=1 NIX_OVERLAYFS_WINESERVER_SHUTDOWN_TIMEOUT=1s \
    ${shutdown} ${fakeWineserver} "$PWD/overlay" app 2> hang.log
  printf '%s\n' "$PWD/overlay  --wait" "$PWD/overlay  -k" "$PWD/overlay  --wait" | diff -u - "$CALLS"
  grep -Fx 'warning: wineserver --wait exceeded 1s for app; killing remaining Wine processes' hang.log

  # No prefix, or no server: nothing to do.
  rm "$CALLS" "$CALLS.killed"
  ${shutdown} ${fakeWineserver} "$PWD/missing" app
  ${shutdown} "$PWD/missing-wineserver" "$PWD/overlay" app
  test ! -e "$CALLS"

  ! ${shutdown} ${fakeWineserver} "$PWD/overlay" 2>/dev/null

  grep -F "nix-overlayfs-wine-shutdown \\" "${package}/libexec/wine-shutdown-setupEnv.sh"
  grep -F "${fakeWineserver} \"\$1\" wine-shutdown-base" "${package}/libexec/wine-shutdown-setupEnv.sh"

  touch "$out"
''
