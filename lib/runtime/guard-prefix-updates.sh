# Usage: nix-overlayfs-guard-prefix-updates APPDIR [LOWERDIR...]
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
# The launcher's integration layer, the highest of the LOWERDIRs (highest
# priority first), has a .update-timestamp that says "disable". The writable
# layer APPDIR must not hide it: a .update-timestamp there (the marker
# launchers wrote before the integration layer existed, or the timestamp of
# an update Wine ran while updates were allowed) is removed.
#
# NIX_OVERLAYFS_WINE_PREFIX_UPDATES=1 restores Wine's default behaviour: APPDIR
# gets the timestamp of the highest LOWERDIR whose file does not start with
# "disable" (or an empty file, which Wine takes like a missing timestamp),
# unless it has a timestamp of its own already.

if [ "$#" -lt 1 ]; then
  echo "usage: nix-overlayfs-guard-prefix-updates APPDIR [LOWERDIR...]" >&2
  exit 2
fi

appdir="$1"
shift
timestamp="$appdir/.update-timestamp"

starts_with_disable() {
  [ "$(head -c 7 -- "$1" 2>/dev/null)" = disable ]
}

if [ "${NIX_OVERLAYFS_WINE_PREFIX_UPDATES:-0}" != 1 ]; then
  rm -f -- "$timestamp"
  exit 0
fi

if [ -f "$timestamp" ] && ! starts_with_disable "$timestamp"; then
  exit 0
fi

source_timestamp=""
for lowerdir in "$@"; do
  if [ -f "$lowerdir/.update-timestamp" ] && ! starts_with_disable "$lowerdir/.update-timestamp"; then
    source_timestamp="$lowerdir/.update-timestamp"
    break
  fi
done

mkdir -p -- "$appdir"
if [ -n "$source_timestamp" ]; then
  cat -- "$source_timestamp" > "$timestamp.tmp.$$"
else
  : > "$timestamp.tmp.$$"
fi
mv -f -- "$timestamp.tmp.$$" "$timestamp"
