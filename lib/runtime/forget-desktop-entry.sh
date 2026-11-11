# Usage: nix-overlayfs-forget-desktop-entry DESKTOP_ID MIMEAPPS_LIST...
#
# Removes DESKTOP_ID from the given mimeapps.list files, after the launcher
# deleted a URL handler .desktop file it had written earlier. A default that
# still names the deleted entry would otherwise hide the handler the system
# (for example a NixOS module) declares. Other entries, comments and sections
# are kept as they are; a key left without entries is dropped. Missing files
# and symlinks (lists managed elsewhere, for example by home-manager) are
# skipped.

if [ "$#" -lt 1 ]; then
  echo "usage: nix-overlayfs-forget-desktop-entry DESKTOP_ID MIMEAPPS_LIST..." >&2
  exit 2
fi

desktop_id="$1"
shift

for list in "$@"; do
  if [ ! -f "$list" ] || [ -L "$list" ]; then
    continue
  fi
  grep -qF -- "$desktop_id" "$list" || continue
  next="$list.tmp.$$"
  awk -v id="$desktop_id" '
    /^[[:space:]]*(#|\[|$)/ || index($0, "=") == 0 || index($0, id) == 0 { print; next }
    {
      key = substr($0, 1, index($0, "=") - 1)
      count = split(substr($0, index($0, "=") + 1), entries, ";")
      kept = ""
      for (i = 1; i <= count; i++)
        if (entries[i] != "" && entries[i] != id) kept = kept entries[i] ";"
      if (kept != "") print key "=" kept
    }
  ' "$list" > "$next"
  if cmp -s -- "$list" "$next"; then
    rm -f -- "$next"
  else
    mv -f -- "$next" "$list"
  fi
done
