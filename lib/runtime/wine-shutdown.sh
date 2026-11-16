# Usage: nix-overlayfs-wine-shutdown WINESERVER OVERLAY_ROOT LABEL
#
# Waits for the Wine server of the prefix mounted at OVERLAY_ROOT to finish
# (wineserver --wait) before the launcher unmounts it. After
# NIX_OVERLAYFS_WINESERVER_SHUTDOWN_TIMEOUT (default 30s) the remaining Wine
# processes are killed (wineserver -k) and waited for another
# NIX_OVERLAYFS_WINESERVER_KILL_TIMEOUT (default 5s). WINEARCH is passed on.
# LABEL names the package in the warning. Does nothing if OVERLAY_ROOT or
# WINESERVER does not exist.

if [ "$#" -ne 3 ]; then
  echo "usage: nix-overlayfs-wine-shutdown WINESERVER OVERLAY_ROOT LABEL" >&2
  exit 2
fi

wineserver="$1"
overlay_root="$2"
label="$3"
shutdown_timeout="${NIX_OVERLAYFS_WINESERVER_SHUTDOWN_TIMEOUT:-30s}"
kill_timeout="${NIX_OVERLAYFS_WINESERVER_KILL_TIMEOUT:-5s}"

[ -d "$overlay_root" ] || exit 0
[ -x "$wineserver" ] || exit 0

if ! timeout --foreground "$shutdown_timeout" \
  env WINEPREFIX="$overlay_root" WINEARCH="${WINEARCH:-}" "$wineserver" --wait 2>/dev/null; then
  echo "warning: wineserver --wait exceeded $shutdown_timeout for $label; killing remaining Wine processes" >&2
  env WINEPREFIX="$overlay_root" WINEARCH="${WINEARCH:-}" "$wineserver" -k 2>/dev/null || true
  timeout --foreground "$kill_timeout" \
    env WINEPREFIX="$overlay_root" WINEARCH="${WINEARCH:-}" "$wineserver" --wait 2>/dev/null || true
fi
