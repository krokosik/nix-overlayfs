{
  pkgs,
  overlayfsLib,
}:
let
  sessions = "${overlayfsLib.runtimeScripts.sessions}/bin/nix-overlayfs-sessions";

  package = overlayfsLib.mkOverlayfsPackage {
    basePackage = pkgs.runCommand "session-sweep-base" {
      pname = "session-sweep-base";
      version = "1.0.0";
    } "mkdir -p $out";
    executableName = "session-sweep";
    executablePath = "/drive_c/windows/system32/notepad.exe";
    launchProgram = "${pkgs.coreutils}/bin/false";
    urlSchemes = [ "sessionsweep" ];
  };
in
pkgs.runCommand "session-sweep-test"
  {
    nativeBuildInputs = [
      pkgs.gawk
      pkgs.gnugrep
      pkgs.util-linux
    ];
  }
  ''
    set -euo pipefail
    base="$PWD/tmpbase"
    mkdir -p "$base"/tmp.{over,held,inherited,legacy,mounted,current} "$base/other"
    for dir in over held inherited mounted current; do
      touch "$base/tmp.$dir/session.lock" "$base/tmp.$dir/file"
    done
    touch "$base/tmp.legacy/file"

    # A session whose launcher still runs holds its lock.
    exec {held}>"$base/tmp.held/session.lock"
    flock "$held"

    # A session whose launcher is gone but whose processes run on (in another
    # namespace, with a cwd outside the directory) still hold the inherited lock.
    (
      exec {inherited}>"$base/tmp.inherited/session.lock"
      flock "$inherited"
      cd /
      exec sleep 300
    ) &
    survivor=$!
    # Wait until the background process holds it (flock then reports 99).
    while flock --nonblock --conflict-exit-code 99 "$base/tmp.inherited/session.lock" true; do
      sleep 0.1
    done

    # Something mounted below a directory in this namespace.
    awk '{ print }' /proc/self/mountinfo > mountinfo
    echo "999 1 0:99 / $base/tmp.mounted/overlay rw - fuse.fuse-overlayfs fuse rw" >> mountinfo

    NIX_OVERLAYFS_MOUNTINFO="$PWD/mountinfo" ${sessions} sweep "$base" "$base/tmp.current"

    test ! -e "$base/tmp.over"
    test -d "$base/tmp.held"
    test -d "$base/tmp.inherited"
    test -d "$base/tmp.legacy"
    test -d "$base/tmp.mounted"
    test -d "$base/tmp.current"
    test -d "$base/other"

    # Once the last process of a session is gone, its directory goes.
    kill "$survivor"
    wait "$survivor" || true
    exec {held}>&-
    ${sessions} sweep "$base" "$base/tmp.current"
    test ! -e "$base/tmp.inherited"
    test ! -e "$base/tmp.held"
    test -d "$base/tmp.legacy"

    ! ${sessions} 2>/dev/null
    ! ${sessions} sweep "$base" 2>/dev/null
    ! ${sessions} claim "$base/tmp.current" 2>/dev/null

    # The launcher creates and locks its directory, and sweeps, under
    # $tmpbase/.lock; it removes the directory when it hands a URL to a
    # running session and leaves.
    script="${package}/bin/session-sweep-unwrapped"
    grep -F 'exec {nix_overlayfs_tmpbase_lock}>"$tmpbase/.lock"' "$script"
    grep -F 'exec {nix_overlayfs_session_lock}>"$tempdir/session.lock"' "$script"
    awk '
      /flock "\$nix_overlayfs_tmpbase_lock"/ && !lock { lock = NR }
      /mktemp -d -p "\$tmpbase"/ && !create { create = NR }
      /nix-overlayfs-sessions sweep/ && !sweep { sweep = NR }
      /exec \{nix_overlayfs_tmpbase_lock\}>&-/ && !unlock { unlock = NR }
      END { exit !(lock && lock < create && create < sweep && sweep < unlock) }
    ' "$script"
    grep -F 'nix_overlayfs_exit_early $?' "$script"
    ! grep -Ex '[[:space:]]*exit \$\?' "$script"

    touch "$out"
  ''
