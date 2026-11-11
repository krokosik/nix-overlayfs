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
      pkgs.procps
    ];
  }
  ''
    set -euo pipefail
    base="$PWD/tmpbase"
    mkdir -p "$base"/tmp.{stale,owned,deadowner,busy,mounted,current} "$base/other"
    touch "$base"/tmp.stale/file

    start_time() {
      local stat rest fields
      stat="$(cat /proc/$1/stat)"
      rest="''${stat##*) }"
      read -r -a fields <<< "$rest"
      echo "''${fields[19]}"
    }

    # A launcher that is still running.
    sleep 300 &
    owner=$!
    echo "$owner $(start_time "$owner")" > "$base/tmp.owned/session.owner"

    # A launcher that is gone, and one whose PID was reused by another process.
    sleep 0 &
    gone=$!
    wait "$gone"
    echo "$gone 1" > "$base/tmp.deadowner/session.owner"
    mkdir "$base/tmp.reused"
    echo "$owner 1" > "$base/tmp.reused/session.owner"

    # A session without session.owner whose processes still work inside it.
    (cd "$base/tmp.busy" && exec sleep 300) &
    busy=$!
    while [ "$(readlink /proc/$busy/cwd)" != "$base/tmp.busy" ]; do sleep 0.1; done

    # Something mounted below a directory.
    awk '{ print }' /proc/self/mountinfo > mountinfo
    echo "999 1 0:99 / $base/tmp.mounted/overlay rw - fuse.fuse-overlayfs fuse rw" >> mountinfo

    NIX_OVERLAYFS_MOUNTINFO="$PWD/mountinfo" ${sessions} sweep "$base" "$base/tmp.current"

    test ! -e "$base/tmp.stale"
    test ! -e "$base/tmp.deadowner"
    test ! -e "$base/tmp.reused"
    test -d "$base/tmp.owned"
    test -d "$base/tmp.busy"
    test -d "$base/tmp.mounted"
    test -d "$base/tmp.current"
    test -d "$base/other"
    kill "$owner" "$busy"

    # claim records the calling launcher.
    mkdir "$base/tmp.claimed"
    bash -c '"$1" claim "$2"; echo $$ > "$2/expected"' _ ${sessions} "$base/tmp.claimed"
    read -r pid start < "$base/tmp.claimed/session.owner"
    test "$pid" = "$(cat "$base/tmp.claimed/expected")"
    test -n "$start"

    ! ${sessions} 2>/dev/null
    ! ${sessions} sweep "$base" 2>/dev/null

    # The launcher claims and sweeps right after creating its directory, and
    # removes it when it hands a URL to a running session and leaves.
    script="${package}/bin/session-sweep-unwrapped"
    grep -F 'nix-overlayfs-sessions claim "$tempdir" || exit 1' "$script"
    grep -F 'nix-overlayfs-sessions sweep "$tmpbase" "$tempdir" || true' "$script"
    grep -F 'nix_overlayfs_exit_early $?' "$script"
    ! grep -Ex '[[:space:]]*exit \$\?' "$script"

    touch "$out"
  ''
