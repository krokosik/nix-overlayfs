# Usage: nix-overlayfs-guard-prefix-updates APPDIR
#
# Wine runs a full prefix update (wineboot: PreInstall, DefaultInstall and
# Wow64Install from wine.inf) when the prefix's .update-timestamp is missing or
# differs from the mtime of Wine's wine.inf. In a layered prefix every file
# that update rewrites lands in the writable layer and from then on hides the
# Nix layers below it, including native DLLs such as DXVK's. The Nix layers
# are the source of truth, so Wine must not update the prefix at runtime.
#
# wineboot skips this automatic, timestamp-driven update when the file starts
# with "disable" (programs/wineboot/wineboot.c, update_timestamp()). It does
# not stop an explicit `wineboot -u`/`--update` (update_wineprefix() is forced
# then) or a program that runs wine.inf's sections itself.
#
# NIX_OVERLAYFS_WINE_PREFIX_UPDATES=1 restores Wine's default behaviour by
# removing the marker again, so the timestamp of the Nix layers applies.

if [ "$#" -ne 1 ]; then
  echo "usage: nix-overlayfs-guard-prefix-updates APPDIR" >&2
  exit 2
fi

appdir="$1"
timestamp="$appdir/.update-timestamp"
current=""
if [ -f "$timestamp" ]; then
  current="$(head -c 7 -- "$timestamp")"
fi

if [ "${NIX_OVERLAYFS_WINE_PREFIX_UPDATES:-0}" = 1 ]; then
  if [ "$current" = disable ]; then
    rm -f -- "$timestamp"
  fi
  exit 0
fi

if [ "$current" = disable ]; then
  exit 0
fi

mkdir -p -- "$appdir"
printf 'disable\n' > "$timestamp.tmp.$$"
mv -f -- "$timestamp.tmp.$$" "$timestamp"
