# Usage:
#   nix-overlayfs-sessions sweep TMPBASE CURRENT_TEMPDIR
#   nix-overlayfs-sessions active STATE_DIR EXECUTABLE_PATH
#   nix-overlayfs-sessions overlay-process-exists OVERLAY_ROOT EXECUTABLE_PATH
#   nix-overlayfs-sessions set-state STATE_DIR ID PHASE
#   nix-overlayfs-sessions forward-url STATE_DIR URL WAIT GENERATION
#   nix-overlayfs-sessions take-url-request STATE_DIR ID
#   nix-overlayfs-sessions terminate SESSION_ID TIMEOUT
#
# sweep: every launch works in its own TMPBASE/tmp.XXXXXXXXXX directory and
# removes it when the session ends; a launcher that is killed leaves it behind.
# Removes the session directories of TMPBASE whose session is over.
#
# A session is over when nothing holds the lock on its session.lock: the
# launcher opens that file and takes an exclusive flock(2) right after
# creating the directory, and the descriptor is inherited by every process of
# the session (in any mount namespace), so the lock lasts until the last of
# them exits. The caller holds a lock on TMPBASE itself, under which launchers create and
# lock their directories, so no directory is claimed while it is swept.
#
# Directories without session.lock (from launchers before this) cannot be
# checked across mount namespaces and are left alone, as are directories with
# anything mounted below them in this namespace.
#
# The other commands keep track of the session of a writable layer, so that a
# URL opened while it runs reaches it instead of starting another one.
# STATE_DIR is the layer's .nix-overlayfs directory. A session exists while
# STATE_DIR/session.lock is locked (see nix-overlayfs-state); the session
# records its id and phase in STATE_DIR/session-state (first line the id,
# second line starting, ready or closing) and takes URLs only from its own
# queue, STATE_DIR/open-requests/ID.
#
# active: whether the session STATE_DIR names still runs: its launcher still
# has the prefix mounted, or some process runs EXECUTABLE_PATH from it. (From
# launchers before session-state; kept for compatibility.)
#
# overlay-process-exists: whether some process runs EXECUTABLE_PATH from the
# prefix mounted at OVERLAY_ROOT.
#
# set-state: records that session ID is in PHASE (starting, ready, closing).
# A starting session gets an empty queue of its own; the queues of earlier
# sessions are removed.
#
# forward-url: hands URL to the session of STATE_DIR and waits until the
# session took it. Exit status:
#   0  the session took the URL (it acknowledged this very request);
#   1  the layer has a newer state generation than GENERATION: nothing was
#      written;
#   3  no session was there when the command started (the lock was free);
#   4  a session is starting or closing, or did not take the URL within
#      WAIT seconds: the URL was withdrawn, try again later;
#   5  a session was there when the command started, but ended before it
#      took the URL: the URL was withdrawn. It belonged to this layer; start
#      a session with it rather than trying another application.
# While the session is starting or closing it waits for it, up to WAIT
# seconds. A URL is published by renaming a complete file into the queue, so
# the session never sees a partial one. Delivery needs a positive
# acknowledgment: the session that takes request.TOKEN writes its id to
# STATE_DIR/open-acks/TOKEN; a request that merely disappears (removed with
# the queue of a session that is over) does not count, and the URL goes to
# the next session. A session that goes on to close takes no more URLs; one
# it has not taken is withdrawn (renamed back) and the command waits again,
# so a URL is never left in the queue of a session that is over.
#
# take-url-request: claims the next URL in the queue of session ID,
# acknowledges it (STATE_DIR/open-acks/TOKEN) and prints it; exits 1 when
# there is none.
#
# terminate: ends the processes left over from a session. The launcher
# starts every session with NIX_OVERLAYFS_SESSION_ID set to an id of its own
# (its session directory), so its processes, and only those, carry it in
# their environment; this sends them SIGTERM and, those still running after
# TIMEOUT (a duration with an optional ms, s, m, h or d suffix), SIGKILL. The
# runtime supervisor normally leaves nothing: this covers a supervisor that
# was killed itself in direct mode, where no PID namespace ends the session.

usage() {
  echo "usage: nix-overlayfs-sessions sweep TMPBASE CURRENT_TEMPDIR | active STATE_DIR EXECUTABLE_PATH | overlay-process-exists OVERLAY_ROOT EXECUTABLE_PATH | set-state STATE_DIR ID PHASE | forward-url STATE_DIR URL WAIT GENERATION | take-url-request STATE_DIR ID | terminate SESSION_ID TIMEOUT" >&2
  exit 2
}

mount_below() {
  local dir="$1"
  awk -v dir="$dir" '
    {
      path = $5
      gsub(/\\040/, " ", path)
      if (path == dir || index(path, dir "/") == 1) found = 1
    }
    END { exit !found }
  ' "${NIX_OVERLAYFS_MOUNTINFO:-/proc/self/mountinfo}"
}

sweep() {
  local tmpbase="$1"
  local current="$2"
  local dir=""
  for dir in "$tmpbase"/tmp.*; do
    if [ ! -d "$dir" ] || [ -L "$dir" ] || [ "$dir" = "$current" ]; then
      continue
    fi
    if [ ! -f "$dir/session.lock" ] || [ -L "$dir/session.lock" ]; then
      continue
    fi
    if ! flock --nonblock --exclusive "$dir/session.lock" true 2>/dev/null; then
      continue
    fi
    if mount_below "$dir"; then
      continue
    fi
    rm -rf --one-file-system -- "$dir" \
      || echo "warning: nix-overlayfs: could not remove stale session directory $dir" >&2
  done
}

overlay_process_exists() {
  local overlay_root="$1"
  local executable_path="$2"
  local candidate=""
  local cmdline_file=""
  local cmdline=""

  for cmdline_file in /proc/[0-9]*/cmdline; do
    [ -r "$cmdline_file" ] || continue
    cmdline="$(tr '\0' ' ' < "$cmdline_file" 2>/dev/null || true)"
    for candidate in \
      "$overlay_root/$executable_path" \
      "$overlay_root/${executable_path#/}"; do
      if [ -n "$cmdline" ] && [[ "$cmdline" == *"$candidate"* ]]; then
        return 0
      fi
    done
  done

  return 1
}

active() {
  local state_dir="$1"
  local executable_path="$2"
  local active_pid=""
  local active_overlay=""

  if [ -f "$state_dir/session.pid" ] && [ -f "$state_dir/overlay-root" ]; then
    active_pid="$(cat "$state_dir/session.pid" 2>/dev/null || true)"
    active_overlay="$(cat "$state_dir/overlay-root" 2>/dev/null || true)"
  fi

  if [ -z "$active_pid" ] || [ -z "$active_overlay" ] || [ ! -d "$active_overlay" ]; then
    return 1
  fi

  if kill -0 "$active_pid" 2>/dev/null \
    && grep -F " $active_overlay " "/proc/$active_pid/mountinfo" >/dev/null 2>&1; then
    return 0
  fi

  overlay_process_exists "$active_overlay" "$executable_path"
}

lock_held() {
  local lock="$1/session.lock"
  [ -f "$lock" ] || return 1
  ! flock --nonblock --shared "$lock" true 2>/dev/null
}

read_state() {
  session_id=""
  session_phase=""
  {
    read -r session_id || true
    read -r session_phase || true
  } < "$1/session-state" 2>/dev/null || true
}

set_state() {
  local state_dir="$1"
  local id="$2"
  local phase="$3"
  local queue=""

  case "$phase" in
    starting | ready | closing) ;;
    *) usage ;;
  esac
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || usage

  if [ "$phase" = starting ]; then
    mkdir -p "$state_dir/open-requests"
    for queue in "$state_dir"/open-requests/* "$state_dir"/open-requests/.[!.]*; do
      [ -e "$queue" ] || [ -L "$queue" ] || continue
      [ "$queue" != "$state_dir/open-requests/$id" ] || continue
      rm -rf -- "$queue"
    done
    mkdir -p "$state_dir/open-requests/$id"
  fi
  printf '%s\n%s\n' "$id" "$phase" > "$state_dir/session-state.$$"
  mv -f "$state_dir/session-state.$$" "$state_dir/session-state"
}

# Exits 1 with a message when the layer is of a newer state generation.
check_generation() {
  local state_dir="$1"
  local generation="$2"
  local found=""

  [ -f "$state_dir/state-generation" ] || return 0
  read -r found < "$state_dir/state-generation" || true
  if ! [[ "$found" =~ ^[0-9]{1,9}$ ]] || [ "$((10#$found))" -gt "$generation" ]; then
    echo "error: nix-overlayfs: the writable layer $(dirname "$state_dir") has state generation ${found:-unknown}, newer than this launcher's ($generation); not handing the URL to its session" >&2
    return 1
  fi
}

# Takes the request back; fails when the session took it first.
withdraw() {
  mv "$1" "$1.withdrawn.$$" 2>/dev/null || return 1
  rm -f "$1.withdrawn.$$"
}

# Prints 0 when session SESSION took request TOKEN (its acknowledgment
# names it), removing the acknowledgment; waits up to two seconds for one,
# since the session writes it right after taking the request.
acknowledged() {
  local state_dir="$1"
  local token="$2"
  local session="$3"
  local ack="$state_dir/open-acks/$token"
  local by=""
  local tries=0

  while [ "$tries" -lt 20 ]; do
    if [ -f "$ack" ]; then
      read -r by < "$ack" || true
      rm -f "$ack"
      [ "$by" = "$session" ]
      return
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  return 1
}

forward_url() {
  local state_dir="$1"
  local url="$2"
  local wait_seconds="$3"
  local generation="$4"
  local deadline=0
  local queue=""
  local pending=""
  local request=""
  local token=""
  local target=""
  local session_id=""
  local session_phase=""

  [[ "$wait_seconds" =~ ^[0-9]+$ ]] || usage
  [[ "$generation" =~ ^[0-9]+$ ]] || usage
  check_generation "$state_dir" "$generation" || return 1
  deadline=$((SECONDS + wait_seconds))

  # 3 only when no session was there at the start; once one was, its end
  # before it took the URL is 5.
  lock_held "$state_dir" || return 3

  while :; do
    lock_held "$state_dir" || return 5
    read_state "$state_dir"
    queue="$state_dir/open-requests/$session_id"
    if [ "$session_phase" = ready ] && [ -n "$session_id" ] && [ -d "$queue" ]; then
      target="$session_id"
      mkdir -p "$state_dir/open-acks" || return 4
      # The queue can go away meanwhile (the session was replaced): look
      # again.
      if ! pending="$(mktemp "$queue/.pending.XXXXXXXXXX" 2>/dev/null)"; then
        [ "$SECONDS" -lt "$deadline" ] || return 4
        sleep 0.2
        continue
      fi
      token="${pending##*/.pending.}"
      request="$queue/request.$token"
      rm -f "$state_dir/open-acks/$token"
      if ! { printf '%s\n' "$url" > "$pending" && mv "$pending" "$request"; } 2>/dev/null; then
        rm -f "$pending"
        [ "$SECONDS" -lt "$deadline" ] || return 4
        sleep 0.2
        continue
      fi
      while :; do
        if [ ! -e "$request" ]; then
          # Taken by the session, or removed with its queue: only the
          # session's acknowledgment counts.
          acknowledged "$state_dir" "$token" "$target" && return 0
          continue 2
        fi
        read_state "$state_dir"
        if [ "$session_phase" != ready ] || [ "$session_id" != "$target" ] \
          || ! lock_held "$state_dir"; then
          # The session closes: take the URL back and wait for the next one.
          if withdraw "$request"; then continue 2; fi
          acknowledged "$state_dir" "$token" "$target" && return 0
          continue 2
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
          if withdraw "$request"; then return 4; fi
          acknowledged "$state_dir" "$token" "$target" && return 0
          return 4
        fi
        sleep 0.1
      done
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 4
    sleep 0.2
  done
}

take_url_request() {
  local state_dir="$1"
  local id="$2"
  local claimed=""
  local request_file=""
  local token=""
  local url=""

  for request_file in "$state_dir/open-requests/$id"/request.*; do
    [ -f "$request_file" ] || continue
    token="${request_file##*/request.}"
    claimed="$state_dir/open-requests/$id/.claimed.$token"
    if ! mv "$request_file" "$claimed" 2>/dev/null; then
      continue
    fi

    url="$(cat "$claimed" 2>/dev/null || true)"
    rm -f "$claimed"
    [ -n "$url" ] || continue

    # The acknowledgment the forwarder waits for, naming this session.
    mkdir -p "$state_dir/open-acks"
    printf '%s\n' "$id" > "$state_dir/open-acks/.$token.$$"
    mv -f "$state_dir/open-acks/.$token.$$" "$state_dir/open-acks/$token"

    printf '%s\n' "$url"
    return 0
  done

  return 1
}

session_processes() {
  local file=""
  local pid=""

  # One grep for all processes: there can be thousands.
  while IFS= read -r file; do
    pid="${file#/proc/}"
    pid="${pid%/environ}"
    [ "$pid" != "$$" ] || continue
    printf '%s\n' "$pid"
  done < <(grep -lzxF -- "NIX_OVERLAYFS_SESSION_ID=$1" /proc/[0-9]*/environ 2>/dev/null || true)
}

now_milliseconds() {
  local now="$EPOCHREALTIME"
  local seconds="${now%[.,]*}"
  local fraction="${now#*[.,]}000"
  echo $((seconds * 1000 + 10#${fraction:0:3}))
}

duration_milliseconds() {
  awk -v value="$1" '
    BEGIN {
      if (!match(value, /^[0-9]+(\.[0-9]+)?/)) exit 1
      number = substr(value, 1, RLENGTH)
      unit = substr(value, RLENGTH + 1)
      if (unit == "ms") factor = 1
      else if (unit == "" || unit == "s") factor = 1000
      else if (unit == "m") factor = 60000
      else if (unit == "h") factor = 3600000
      else if (unit == "d") factor = 86400000
      else exit 1
      printf "%d\n", number * factor
    }
  '
}

terminate() {
  local session_id="$1"
  local timeout_ms=""
  local start_ms=""
  local elapsed_ms=0
  local reported=0
  local -a pids=()

  [ -n "$session_id" ] || return 2
  timeout_ms="$(duration_milliseconds "$2")" || {
    echo "error: nix-overlayfs: invalid duration: $2" >&2
    return 2
  }

  start_ms="$(now_milliseconds)"
  while :; do
    mapfile -t pids < <(session_processes "$session_id")
    [ "${#pids[@]}" -gt 0 ] || return 0
    if [ "$reported" = 0 ]; then
      echo "warning: nix-overlayfs: terminating processes left over from the session" >&2
      reported=1
    fi
    elapsed_ms=$(($(now_milliseconds) - start_ms))
    if [ "$elapsed_ms" -ge $((timeout_ms + 5000)) ]; then
      echo "warning: nix-overlayfs: processes of the session do not end: ${pids[*]}" >&2
      return 1
    elif [ "$elapsed_ms" -ge "$timeout_ms" ]; then
      kill -KILL "${pids[@]}" 2>/dev/null || true
    else
      kill -TERM "${pids[@]}" 2>/dev/null || true
    fi
    sleep 0.1
  done
}

case "${1:-}" in
  sweep)
    [ "$#" -eq 3 ] || usage
    sweep "$2" "$3"
    ;;
  active)
    [ "$#" -eq 3 ] || usage
    active "$2" "$3"
    ;;
  overlay-process-exists)
    [ "$#" -eq 3 ] || usage
    overlay_process_exists "$2" "$3"
    ;;
  set-state)
    [ "$#" -eq 4 ] || usage
    set_state "$2" "$3" "$4"
    ;;
  forward-url)
    [ "$#" -eq 5 ] || usage
    forward_url "$2" "$3" "$4" "$5"
    ;;
  take-url-request)
    [ "$#" -eq 3 ] || usage
    take_url_request "$2" "$3"
    ;;
  terminate)
    [ "$#" -eq 3 ] || usage
    terminate "$2" "$3"
    ;;
  *)
    usage
    ;;
esac
