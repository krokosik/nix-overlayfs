# Usage:
#   nix-overlayfs-sessions sweep TMPBASE CURRENT_TEMPDIR
#   nix-overlayfs-sessions active STATE_DIR EXECUTABLE_PATH
#   nix-overlayfs-sessions overlay-process-exists OVERLAY_ROOT EXECUTABLE_PATH
#   nix-overlayfs-sessions enqueue-url STATE_DIR URL
#   nix-overlayfs-sessions take-url-request STATE_DIR
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
# The other commands keep track of the running session of a writable layer,
# so that a URL opened while it runs reaches it instead of starting another
# one. STATE_DIR is the layer's .nix-overlayfs directory; the running session
# writes its launcher's process id to STATE_DIR/session.pid and its mounted
# prefix to STATE_DIR/overlay-root.
#
# active: whether the session STATE_DIR names still runs: its launcher still
# has the prefix mounted, or some process runs EXECUTABLE_PATH from it.
#
# overlay-process-exists: whether some process runs EXECUTABLE_PATH from the
# prefix mounted at OVERLAY_ROOT.
#
# enqueue-url: hands URL to the running session.
#
# take-url-request: claims the next URL handed to the session and prints it;
# exits 1 when there is none.
#
# terminate: ends the processes left over from a session. The launcher
# starts every session with NIX_OVERLAYFS_SESSION_ID set to an id of its own
# (its session directory), so its processes, and only those, carry it in
# their environment; this sends them SIGTERM and, those still running after
# TIMEOUT (a duration with an optional ms, s, m, h or d suffix), SIGKILL. The
# runtime supervisor normally leaves nothing: this covers a supervisor that
# was killed itself in direct mode, where no PID namespace ends the session.

usage() {
  echo "usage: nix-overlayfs-sessions sweep TMPBASE CURRENT_TEMPDIR | active STATE_DIR EXECUTABLE_PATH | overlay-process-exists OVERLAY_ROOT EXECUTABLE_PATH | enqueue-url STATE_DIR URL | take-url-request STATE_DIR | terminate SESSION_ID TIMEOUT" >&2
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

enqueue_url() {
  local state_dir="$1"
  local url="$2"
  local request_file=""

  mkdir -p "$state_dir/open-requests"
  request_file="$(mktemp "$state_dir/open-requests/request.XXXXXXXXXX")"
  printf '%s\n' "$url" > "$request_file"
}

take_url_request() {
  local state_dir="$1"
  local processing_file=""
  local request_file=""
  local url=""

  mkdir -p "$state_dir/open-requests"
  for request_file in "$state_dir"/open-requests/request.*; do
    [ -f "$request_file" ] || continue
    processing_file="$request_file.processing.$$"
    if ! mv "$request_file" "$processing_file" 2>/dev/null; then
      continue
    fi

    url="$(cat "$processing_file" 2>/dev/null || true)"
    rm -f "$processing_file"
    [ -n "$url" ] || continue

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
  enqueue-url)
    [ "$#" -eq 3 ] || usage
    enqueue_url "$2" "$3"
    ;;
  take-url-request)
    [ "$#" -eq 2 ] || usage
    take_url_request "$2"
    ;;
  terminate)
    [ "$#" -eq 3 ] || usage
    terminate "$2" "$3"
    ;;
  *)
    usage
    ;;
esac
