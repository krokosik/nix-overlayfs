# Usage:
#   nix-overlayfs-sessions sweep TMPBASE CURRENT_TEMPDIR
#   nix-overlayfs-sessions active STATE_DIR EXECUTABLE_PATH
#   nix-overlayfs-sessions overlay-process-exists OVERLAY_ROOT EXECUTABLE_PATH
#   nix-overlayfs-sessions enqueue-url STATE_DIR URL
#   nix-overlayfs-sessions take-url-request STATE_DIR
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

usage() {
  echo "usage: nix-overlayfs-sessions sweep TMPBASE CURRENT_TEMPDIR | active STATE_DIR EXECUTABLE_PATH | overlay-process-exists OVERLAY_ROOT EXECUTABLE_PATH | enqueue-url STATE_DIR URL | take-url-request STATE_DIR" >&2
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
  *)
    usage
    ;;
esac
