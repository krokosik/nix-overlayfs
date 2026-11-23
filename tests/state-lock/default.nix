# A second launch against a writable layer whose session lock is held stops
# before it changes anything in the layer, and says who holds the lock; so
# does a launch against a layer of a newer state generation. Runs the real
# launcher in the build sandbox: it never gets as far as mounting.
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
    # -o: the lock goes with flock itself, not with sleep.
    flock -o "$lock" sleep 300 &
    holder=$!
    trap 'kill "$holder" 2>/dev/null || true' EXIT
    while flock --nonblock "$lock" true; do sleep 0.05; done
    printf '%s\n' "$holder" > "$lock"

    status=0
    ${package}/bin/state-lock > second.log 2>&1 || status=$?
    cat second.log
    test "$status" -eq 75
    grep -F "error: nix-overlayfs: state-lock-base already runs from $appdir:" second.log
    grep -F "process $holder (flock -o $lock sleep 300)" second.log

    # Nothing in the writable layer changed: no registry, no shadow check,
    # no overlay workdir, no broker directory, the holder's pid kept.
    test "$(ls -A "$appdir")" = .nix-overlayfs
    test "$(ls -A "$state_dir")" = session.lock
    test ! -e "$(dirname "$appdir")/.state-lock-base.nix-overlayfs-work"
    test "$(cat "$lock")" = "$holder"
    # Its session directory is gone again.
    test -z "$(ls -A "$tmpbase")"

    # A URL opened or forwarded while the session is not ready (here: it
    # never says so) neither starts a second session nor is queued: after
    # NIX_OVERLAYFS_URL_FORWARD_WAIT seconds the caller is told to retry (4).
    for mode in open-url forward-url; do
      status=0
      NIX_OVERLAYFS_URL_FORWARD_WAIT=1 ${package}/bin/state-lock --nix-overlayfs-$mode state-lock-test:starting \
        2>/dev/null || status=$?
      test "$status" -eq 4
    done
    test "$(ls -A "$state_dir")" = session.lock
    test ! -e "$appdir/system.reg"

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

    # A layer of a newer state generation: the launch takes the lock, then
    # refuses before it changes anything else, naming both launchers.
    kill "$holder"
    wait "$holder" || true
    newer=$((${toString overlayfsLib.stateGeneration} + 1))
    printf '%s\n%s\n%s\n' "$newer" /nix/store/newer-launcher 2030-01-01T00:00:00Z > "$state_dir/state-generation"
    cp "$state_dir/state-generation" newer-marker
    printf 'recorded\n' > "$lock"
    status=0
    ${package}/bin/state-lock > newer.log 2>&1 || status=$?
    cat newer.log
    test "$status" -eq 1
    grep -F "has state generation $newer (written by /nix/store/newer-launcher on 2030-01-01T00:00:00Z)" newer.log
    grep -F "this launcher (${package}) only knows generation ${toString overlayfsLib.stateGeneration}" newer.log
    cmp newer-marker "$state_dir/state-generation"
    # The lock's pid record is written only after the check.
    test "$(cat "$lock")" = recorded
    # URLs are not handed to a session of a newer generation either.
    status=0
    ${package}/bin/state-lock --nix-overlayfs-forward-url state-lock-test:newer 2>/dev/null || status=$?
    test "$status" -eq 1
    test "$(ls -A "$appdir")" = .nix-overlayfs
    test "$(ls -A "$state_dir")" = "$(printf 'session.lock\nstate-generation')"
    test -z "$(ls -A "$tmpbase")"
    flock --nonblock "$lock" true

    # The program itself: a layer without the marker is accepted and gets
    # it, as does one of an older generation; garbage is refused.
    mkdir gen
    ${state} check-generation gen 3 /nix/store/three
    test "$(head -n 2 gen/state-generation)" = "$(printf '3\n/nix/store/three')"
    ${state} check-generation gen 3 /nix/store/three-again
    test "$(sed -n 2p gen/state-generation)" = /nix/store/three-again
    ${state} check-generation gen 4 /nix/store/four
    test "$(head -n 1 gen/state-generation)" = 4
    ! ${state} check-generation gen 3 /nix/store/three 2>/dev/null
    test "$(head -n 1 gen/state-generation)" = 4
    printf '99999999999999999999\n' > gen/state-generation
    ! ${state} check-generation gen 3 /nix/store/three 2>/dev/null
    printf 'garbage\n' > gen/state-generation
    ! ${state} check-generation gen 3 /nix/store/three 2> garbage.log
    grep -F 'is not a state generation' garbage.log
    ! ${state} check-generation gen x /nix/store/three 2>/dev/null
    ! ${state} check-generation gen 3 2>/dev/null

    touch "$out"
  ''
