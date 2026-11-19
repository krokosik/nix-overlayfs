# A second launch against a writable layer whose session lock is held stops
# before it changes anything in the layer, and says who holds the lock. Runs
# the real launcher in the build sandbox: it never gets as far as mounting.
{
  pkgs,
  overlayfsLib,
}:
let
  package = overlayfsLib.mkOverlayfsPackage {
    basePackage = pkgs.runCommand "state-lock-base" {
      pname = "state-lock-base";
      version = "1.0.0";
    } "mkdir -p $out; touch $out/probe";
    executableName = "state-lock";
    executablePath = "/probe";
    launchProgram = "${pkgs.coreutils}/bin/touch";
    urlSchemes = [ "state-lock-test" ];
  };
  state = "${overlayfsLib.runtimeScripts.state}/bin/nix-overlayfs-state";
in
pkgs.runCommand "state-lock-test"
  {
    nativeBuildInputs = [
      pkgs.util-linux
      pkgs.gnugrep
    ];
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR/home"
    unset XDG_DATA_HOME XDG_CACHE_HOME
    appdir="$HOME/.local/share/state-lock-base"
    state_dir="$appdir/.nix-overlayfs"
    lock="$state_dir/session.lock"
    tmpbase="$HOME/.cache/nix-overlayfs/tmp"
    mkdir -p "$state_dir"

    # Another session holds the lock.
    flock "$lock" sleep 300 &
    holder=$!
    trap 'kill "$holder" 2>/dev/null || true' EXIT
    while flock --nonblock "$lock" true; do sleep 0.05; done
    printf '%s\n' "$holder" > "$lock"

    status=0
    ${package}/bin/state-lock > second.log 2>&1 || status=$?
    cat second.log
    test "$status" -eq 75
    grep -F "error: nix-overlayfs: state-lock-base already runs from $appdir:" second.log
    grep -F "process $holder (flock $lock sleep 300)" second.log

    # Nothing in the writable layer changed: no registry, no shadow check,
    # no overlay workdir, no broker directory, the holder's pid kept.
    test "$(ls -A "$appdir")" = .nix-overlayfs
    test "$(ls -A "$state_dir")" = session.lock
    test ! -e "$(dirname "$appdir")/.state-lock-base.nix-overlayfs-work"
    test "$(cat "$lock")" = "$holder"
    # Its session directory is gone again.
    test -z "$(ls -A "$tmpbase")"

    # A URL opened while the session starts (it has not registered yet) is
    # queued for it instead of starting a second session.
    ${package}/bin/state-lock --nix-overlayfs-open-url state-lock-test:starting 2> open.log
    grep -F 'state-lock-test:starting' "$state_dir"/open-requests/request.*
    test "$(ls -A "$state_dir")" = "$(printf 'open-requests\nsession.lock')"
    test ! -e "$appdir/system.reg"

    # Forwarding only still reports that no session is registered.
    status=0
    ${package}/bin/state-lock --nix-overlayfs-forward-url state-lock-test:forward 2>/dev/null || status=$?
    test "$status" -eq 3

    # The process that took the lock has exited, but its supervisor still
    # holds the lock.
    sh -c 'exit 0' &
    gone=$!
    wait "$gone"
    printf '%s\n' "$gone" > "$lock"
    status=0
    ${package}/bin/state-lock > exited.log 2>&1 || status=$?
    test "$status" -eq 75
    grep -F "process $gone, which has exited; its session is still shutting down" exited.log

    # Without a recorded process the holder is unknown.
    : > "$lock"
    test "$(${state} describe-holder "$state_dir")" = "an unknown process"
    ! ${state} 2>/dev/null
    ! ${state} describe-holder 2>/dev/null

    touch "$out"
  ''
