# Usage:
#   nix-overlayfs-namespace mode MODE PROBE_LOG
#   nix-overlayfs-namespace hide-ld-so-preload TEMPDIR
#   nix-overlayfs-namespace unmount MOUNTPOINT
#
# mode: resolves the namespace mode the launcher runs in. MODE is auto,
# required or direct; auto becomes required when an unprivileged user and
# mount namespace can be created, and direct (FUSE in the caller's namespace)
# when the kernel or a sandbox forbids it. Prints the result. Exits 2 for an
# unknown MODE and 1 when the probe fails for another reason; the probe's
# messages go to PROBE_LOG and are repeated on stderr.
#
# hide-ld-so-preload: in the launcher's own mount namespace, binds an empty
# file (TEMPDIR/empty-ld.so.preload) over /etc/ld.so.preload, whose host
# libraries would otherwise be loaded into Wine. Does nothing in direct mode
# (NIX_OVERLAYFS_DIRECT_MODE=1), with NIX_OVERLAYFS_PRESERVE_LD_SO_PRELOAD=1,
# or without the file. A failed mount is only a warning.
#
# unmount: unmounts the prefix at MOUNTPOINT (lazily if it is busy). Exits 1
# with a warning if it is still mounted afterwards.

usage() {
  echo "usage: nix-overlayfs-namespace mode MODE PROBE_LOG | hide-ld-so-preload TEMPDIR | unmount MOUNTPOINT" >&2
  exit 2
}

resolve_mode() {
  local mode="$1"
  local probe_log="$2"

  case "$mode" in
    auto | required | direct) ;;
    *)
      echo "error: NIX_OVERLAYFS_NAMESPACE_MODE must be one of: auto, required, direct" >&2
      return 2
      ;;
  esac

  if [ "$mode" = auto ]; then
    if unshare --map-root-user --mount true 2>"$probe_log"; then
      mode=required
    elif grep -Eq '(uid_map|gid_map).*(Operation not permitted|Permission denied)|(unshare failed:|cannot create user namespace:).*(Operation not permitted|Permission denied)' "$probe_log"; then
      echo "warning: nix-overlayfs: user/mount namespaces are unavailable; using direct FUSE mode" >&2
      sed 's/^/warning: nix-overlayfs: unshare: /' "$probe_log" >&2
      mode=direct
    else
      echo "error: nix-overlayfs: namespace capability probe failed unexpectedly" >&2
      cat "$probe_log" >&2
      return 1
    fi
  fi

  printf '%s\n' "$mode"
}

hide_ld_so_preload() {
  local tempdir="$1"
  # Tests point this at a file of their own.
  local preload="${NIX_OVERLAYFS_LD_SO_PRELOAD_PATH:-/etc/ld.so.preload}"

  if [ "${NIX_OVERLAYFS_DIRECT_MODE:-0}" = 1 ] \
    || [ "${NIX_OVERLAYFS_PRESERVE_LD_SO_PRELOAD:-0}" = 1 ] \
    || [ ! -f "$preload" ]; then
    return 0
  fi

  : > "$tempdir/empty-ld.so.preload"
  if ! mount --bind "$tempdir/empty-ld.so.preload" "$preload"; then
    echo "warning: failed to hide /etc/ld.so.preload in Wine mount namespace" >&2
  fi
}

unmount_prefix() {
  local mountpoint="$1"

  if [ -d "$mountpoint" ]; then
    fusermount3 -u "$mountpoint" 2>/dev/null \
      || fusermount3 -uz "$mountpoint" 2>/dev/null \
      || umount -l "$mountpoint" 2>/dev/null \
      || true
  fi
  if mountpoint -q "$mountpoint"; then
    echo "warning: failed to unmount nix-overlayfs runtime at $mountpoint" >&2
    return 1
  fi
}

case "${1:-}" in
  mode)
    [ "$#" -eq 3 ] || usage
    resolve_mode "$2" "$3"
    ;;
  hide-ld-so-preload)
    [ "$#" -eq 2 ] || usage
    hide_ld_so_preload "$2"
    ;;
  unmount)
    [ "$#" -eq 2 ] || usage
    unmount_prefix "$2"
    ;;
  *)
    usage
    ;;
esac
