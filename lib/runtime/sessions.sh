# Usage: nix-overlayfs-sessions claim TEMPDIR
#        nix-overlayfs-sessions sweep TMPBASE CURRENT_TEMPDIR
#
# Every launch works in its own TMPBASE/tmp.XXXXXXXXXX directory and removes it
# when the session ends. A launcher that is killed, or that crashes, leaves its
# directory behind. "claim" records the calling launcher (its PID and process
# start time, so a reused PID does not count) in TEMPDIR/session.owner; "sweep"
# removes the session directories of TMPBASE whose session is over.
#
# A directory is kept while its owner runs, while any process works inside it
# (a session whose launcher died, or one started by a launcher without
# session.owner), or while anything is mounted below it.

proc_start_time() {
  local stat rest fields
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  # Fields after "pid (comm) "; the start time is field 22 of the whole line.
  rest="${stat##*) }"
  read -r -a fields <<< "$rest"
  printf '%s\n' "${fields[19]}"
}

owner_alive() {
  local owner="$1/session.owner" pid="" start=""
  [ -r "$owner" ] || return 1
  read -r pid start < "$owner" || true
  if [ -z "$pid" ] || [ -z "$start" ]; then
    return 1
  fi
  [ "$(proc_start_time "$pid" || true)" = "$start" ]
}

process_inside() {
  local dir="$1" cwd target
  for cwd in /proc/[0-9]*/cwd; do
    target="$(readlink "$cwd" 2>/dev/null)" || continue
    case "$target" in
      "$dir" | "$dir"/*) return 0 ;;
    esac
  done
  return 1
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

case "${1:-}" in
  claim)
    [ "$#" -eq 2 ] || {
      echo "usage: nix-overlayfs-sessions claim TEMPDIR" >&2
      exit 2
    }
    owner_start="$(proc_start_time "$PPID")"
    printf '%s %s\n' "$PPID" "$owner_start" > "$2/session.owner.$$"
    mv -f -- "$2/session.owner.$$" "$2/session.owner"
    ;;
  sweep)
    [ "$#" -eq 3 ] || {
      echo "usage: nix-overlayfs-sessions sweep TMPBASE CURRENT_TEMPDIR" >&2
      exit 2
    }
    tmpbase="$2"
    current="$3"
    for dir in "$tmpbase"/tmp.*; do
      if [ ! -d "$dir" ] || [ -L "$dir" ] || [ "$dir" = "$current" ]; then
        continue
      fi
      if owner_alive "$dir" || process_inside "$dir" || mount_below "$dir"; then
        continue
      fi
      rm -rf --one-file-system -- "$dir" \
        || echo "warning: nix-overlayfs: could not remove stale session directory $dir" >&2
    done
    ;;
  *)
    echo "usage: nix-overlayfs-sessions claim TEMPDIR | sweep TMPBASE CURRENT_TEMPDIR" >&2
    exit 2
    ;;
esac
