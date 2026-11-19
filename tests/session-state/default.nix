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

    # A starting session gets an empty queue of its own; queues of earlier
    # sessions (and requests of launchers before them) go.
    mkdir -p "$state/open-requests/tmp.old"
    printf 'app://stale\n' > "$state/open-requests/tmp.old/request.x"
    printf 'app://flat\n' > "$state/open-requests/request.flat"
    ${sessions} set-state "$state" tmp.one starting
    test "$(ls -A "$state/open-requests")" = tmp.one
    test "$(cat "$state/session-state")" = "$(printf 'tmp.one\nstarting')"
    ! ${sessions} set-state "$state" tmp.one running 2>/dev/null
    ! ${sessions} set-state "$state" ../x ready 2>/dev/null

    # The session takes only complete requests of its own queue, each once:
    # a file still being written (.pending.*) is not taken.
    queue="$state/open-requests/tmp.one"
    ! ${sessions} take-url-request "$state" tmp.one
    printf 'app://one?a=1&b=2\n' > "$queue/request.a"
    printf 'app://two\n' > "$queue/request.b"
    : > "$queue/request.empty"
    : > "$queue/.pending.c"
    taken=()
    while url="$(${sessions} take-url-request "$state" tmp.one)"; do
      taken+=("$url")
    done
    test "''${#taken[@]}" -eq 2
    printf '%s\n' 'app://one?a=1&b=2' app://two | diff -u - <(printf '%s\n' "''${taken[@]}" | sort)
    test "$(ls -A "$queue")" = .pending.c
    rm "$queue/.pending.c"

    # forward-url: no session at all.
    status=0
    ${sessions} forward-url "$PWD/nostate" app://x 0 1 || status=$?
    test "$status" -eq 3
    # The lock file exists but is free.
    touch "$state/session.lock"
    status=0
    ${sessions} forward-url "$state" app://x 5 1 || status=$?
    test "$status" -eq 3

    # A session holds the lock (-o: the lock goes with flock, not sleep).
    flock -o "$state/session.lock" sleep 300 &
    holder=$!
    while flock --nonblock "$state/session.lock" true; do sleep 0.05; done

    # Starting: retry later (4), nothing queued.
    status=0
    ${sessions} forward-url "$state" app://early 0 1 || status=$?
    test "$status" -eq 4
    test -z "$(ls -A "$queue")"

    # Starting, then ready within the wait: the URL reaches the session.
    (
      sleep 1
      ${sessions} set-state "$state" tmp.one ready
      until url="$(${sessions} take-url-request "$state" tmp.one)"; do sleep 0.1; done
      printf '%s\n' "$url" > took
    ) &
    consumer=$!
    ${sessions} forward-url "$state" 'app://ready?x=1' 10 1
    wait "$consumer"
    test "$(cat took)" = 'app://ready?x=1'
    test -z "$(ls -A "$queue")"

    # Ready, but the session does not take it within the wait: withdrawn, 4.
    status=0
    ${sessions} forward-url "$state" app://untaken 1 1 || status=$?
    test "$status" -eq 4
    test -z "$(ls -A "$queue")"

    # The session closes before it takes the URL: the forwarder takes it back
    # and waits; once the session is over there is none (3), and nothing is
    # left for a later session.
    ${sessions} forward-url "$state" app://closing 20 1 > /dev/null &
    forwarder=$!
    until ls "$queue"/request.* >/dev/null 2>&1; do sleep 0.05; done
    ${sessions} set-state "$state" tmp.one closing
    sleep 0.5
    test -z "$(ls -A "$queue")"
    kill "$holder"
    wait "$holder" || true
    status=0
    wait "$forwarder" || status=$?
    test "$status" -eq 3
    test -z "$(ls -A "$queue")"

    # Closing: retry later.
    flock -o "$state/session.lock" sleep 300 &
    holder=$!
    while flock --nonblock "$state/session.lock" true; do sleep 0.05; done
    status=0
    ${sessions} forward-url "$state" app://late 0 1 || status=$?
    test "$status" -eq 4

    # A layer of a newer state generation: refused, nothing written.
    ${sessions} set-state "$state" tmp.one ready
    printf '2\n/nix/store/newer\n' > "$state/state-generation"
    status=0
    ${sessions} forward-url "$state" app://newer 0 1 2> newer.log || status=$?
    test "$status" -eq 1
    grep -F 'state generation 2' newer.log
    test -z "$(ls -A "$queue")"
    rm "$state/state-generation"
    kill "$holder"
    wait "$holder" || true

    ! ${sessions} forward-url "$state" app://x 2>/dev/null
    ! ${sessions} forward-url "$state" app://x soon 1 2>/dev/null

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
    ! ${sessions} take-url-request "$state" 2>/dev/null

    # The launcher scripts use these commands instead of their own copies.
    for script in "${package}/bin/session-state-unwrapped" "${package}/libexec/session-state-setupEnv.sh"; do
      ! grep -F '/proc/[0-9]*/cmdline' "$script"
    done
    grep -F 'nix-overlayfs-sessions forward-url "$state_dir" "$callback_url"' "${package}/bin/session-state-unwrapped"
    grep -F 'nix-overlayfs-sessions take-url-request "$state_dir" "''${tempdir##*/}"' "${package}/libexec/session-state-setupEnv.sh"
    grep -F 'set-state "$state_dir" "''${tempdir##*/}" ready' "${package}/libexec/session-state-setupEnv.sh"
    grep -F 'set-state "$state_dir" "''${tempdir##*/}" closing' "${package}/libexec/session-state-setupEnv.sh"

    touch "$out"
  ''
