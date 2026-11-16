{
  pkgs,
  overlayfsLib,
}:
let
  broker = "${overlayfsLib.runtimeScripts.hostBrowserBroker}/bin/nix-overlayfs-host-browser-broker";

  opener = pkgs.writeShellScript "fake-host-url-opener" ''
    printf '%s\n' "$*" >> "$OPENED"
    case "$2" in
      *fail*) exit 1 ;;
    esac
  '';

  package = overlayfsLib.mkOverlayfsPackage {
    basePackage = pkgs.runCommand "host-browser-broker-base" {
      pname = "host-browser-broker-base";
      version = "1.0.0";
    } "mkdir -p $out";
    executableName = "host-browser-broker";
    executablePath = "/drive_c/windows/system32/notepad.exe";
    launchProgram = "${pkgs.coreutils}/bin/false";
  };
in
pkgs.runCommand "host-browser-broker-test" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -euo pipefail
  export OPENED="$PWD/opened"
  requests="$PWD/requests"
  mkdir -p "$requests"

  printf 'https://example.invalid/one\n' > "$requests/request.one"
  printf 'https://example.invalid/fail\n' > "$requests/request.fail"
  : > "$requests/request.empty"
  # Still being written, or claimed by another broker.
  printf 'https://example.invalid/partial\n' > "$requests/request.partial.tmp"
  printf 'https://example.invalid/claimed\n' > "$requests/request.claimed.processing.1"

  ${broker} "$requests" ${opener} 2> broker.log &
  pid=$!
  for _ in $(seq 100); do
    [ "$(grep -c . "$OPENED" 2>/dev/null)" = 2 ] && break
    sleep 0.1
  done
  # Requests that arrive while it runs.
  printf 'https://example.invalid/two\n' > "$requests/request.two"
  for _ in $(seq 100); do
    [ ! -e "$requests/request.two" ] && break
    sleep 0.1
  done
  touch "$requests/.stop"
  wait "$pid"

  sort "$OPENED" > opened.sorted
  printf '%s\n' \
    '--direct https://example.invalid/fail' \
    '--direct https://example.invalid/one' \
    '--direct https://example.invalid/two' \
    | diff -u - opened.sorted
  grep -Fx 'warning: failed to open URL with host browser: https://example.invalid/fail' broker.log
  test ! -e "$requests/request.one"
  test ! -e "$requests/request.empty"
  test -e "$requests/request.partial.tmp"
  test -e "$requests/request.claimed.processing.1"

  # Asked to stop, it still handles what is left once.
  printf 'https://example.invalid/late\n' > "$requests/request.late"
  ${broker} "$requests" ${opener}
  grep -Fx -- '--direct https://example.invalid/late' "$OPENED"
  test ! -e "$requests/request.late"

  ! ${broker} "$requests" 2>/dev/null

  # The launcher runs it for the session and stops it at the end.
  script="${package}/bin/host-browser-broker-unwrapped"
  grep -F 'nix-overlayfs-host-browser-broker \' "$script"
  grep -F 'touch "$host_browser_request_dir/.stop"' "$script"

  touch "$out"
''
