{
  pkgs,
  overlayfsLib,
}:
let
  sessions = "${overlayfsLib.runtimeScripts.sessions}/bin/nix-overlayfs-sessions";

  package = overlayfsLib.mkOverlayfsPackage {
    basePackage = pkgs.runCommand "session-state-base" {
      pname = "session-state-base";
      version = "1.0.0";
    } "mkdir -p $out";
    executableName = "session-state";
    executablePath = "/drive_c/app/app.exe";
    launchProgram = "${pkgs.coreutils}/bin/false";
    urlSchemes = [ "sessionstate" ];
  };
in
pkgs.runCommand "session-state-test"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.util-linux
    ];
  }
  ''
    set -euo pipefail
    state="$PWD/state"
    mkdir -p "$state"

    # URLs handed to the running session are taken once each.
    ! ${sessions} take-url-request "$state"
    ${sessions} enqueue-url "$state" 'app://one?a=1&b=2'
    ${sessions} enqueue-url "$state" 'app://two'
    : > "$state/open-requests/request.empty"
    taken=()
    while url="$(${sessions} take-url-request "$state")"; do
      taken+=("$url")
    done
    test "''${#taken[@]}" -eq 2
    printf '%s\n' 'app://one?a=1&b=2' app://two | diff -u - <(printf '%s\n' "''${taken[@]}" | sort)
    test -z "$(ls -A "$state/open-requests")"

    # No running session: no state, or a launcher and application that are gone.
    overlay="$PWD/tmp.session/overlay"
    mkdir -p "$overlay"
    ! ${sessions} active "$state" /drive_c/app/app.exe
    sh -c 'exit 0' &
    gone=$!
    wait "$gone"
    echo "$gone" > "$state/session.pid"
    echo "$overlay" > "$state/overlay-root"
    ! ${sessions} active "$state" /drive_c/app/app.exe
    ! ${sessions} overlay-process-exists "$overlay" /drive_c/app/app.exe

    # The application still runs from the prefix (with or without a leading
    # slash in its path).
    # (bash, since the multi-call coreutils binary goes by its argv[0])
    ( exec -a "$overlay/drive_c/app/app.exe" bash -c 'while :; do sleep 1; done' ) &
    app=$!
    for _ in $(seq 100); do
      grep -qaF "$overlay/drive_c/app/app.exe" "/proc/$app/cmdline" 2>/dev/null && break
      sleep 0.1
    done
    ${sessions} active "$state" /drive_c/app/app.exe
    ${sessions} active "$state" drive_c/app/app.exe
    ${sessions} overlay-process-exists "$overlay" /drive_c/app/app.exe
    ! ${sessions} overlay-process-exists "$overlay" /drive_c/app/other.exe
    kill "$app"
    wait "$app" || true

    # The launcher runs and has the prefix mounted ("/" stands in for a mount
    # every process sees).
    echo $$ > "$state/session.pid"
    echo / > "$state/overlay-root"
    ${sessions} active "$state" /drive_c/app/app.exe
    # A prefix that no longer exists.
    echo "$PWD/missing" > "$state/overlay-root"
    ! ${sessions} active "$state" /drive_c/app/app.exe

    ! ${sessions} record-env "$state" 2>/dev/null
    ! ${sessions} active "$state" 2>/dev/null
    ! ${sessions} enqueue-url "$state" 2>/dev/null

    # Both launcher scripts use these commands instead of their own copies.
    for script in "${package}/bin/session-state-unwrapped" "${package}/libexec/session-state-setupEnv.sh"; do
      grep -F "nix-overlayfs-sessions active \"\$state_dir\" /drive_c/app/app.exe" "$script"
      grep -F 'nix-overlayfs-sessions enqueue-url "$state_dir" "$callback_url"' "$script"
      ! grep -F '/proc/[0-9]*/cmdline' "$script"
    done
    grep -F 'nix-overlayfs-sessions take-url-request "$state_dir"' "${package}/libexec/session-state-setupEnv.sh"

    touch "$out"
  ''
