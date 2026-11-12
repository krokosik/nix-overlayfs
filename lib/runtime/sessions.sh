# Usage: nix-overlayfs-sessions sweep TMPBASE CURRENT_TEMPDIR
#
# Every launch works in its own TMPBASE/tmp.XXXXXXXXXX directory and removes it
# when the session ends; a launcher that is killed leaves it behind. Removes
# the session directories of TMPBASE whose session is over.
#
# A session is over when nothing holds the lock on its session.lock: the
# launcher opens that file and takes an exclusive flock(2) right after
# creating the directory, and the descriptor is inherited by every process of
# the session (in any mount namespace), so the lock lasts until the last of
# them exits. The caller holds TMPBASE/.lock, under which launchers create and
# lock their directories, so no directory is claimed while it is swept.
#
# Directories without session.lock (from launchers before this) cannot be
# checked across mount namespaces and are left alone, as are directories with
# anything mounted below them in this namespace.

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

if [ "$#" -ne 3 ] || [ "$1" != sweep ]; then
  echo "usage: nix-overlayfs-sessions sweep TMPBASE CURRENT_TEMPDIR" >&2
  exit 2
fi

tmpbase="$2"
current="$3"
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
