# Usage:
#   nix-overlayfs-upper-layer skeleton APPDIR LOWERDIR...
#   nix-overlayfs-upper-layer install-start-shim APPDIR SHIM
#   nix-overlayfs-upper-layer remove-start-shim APPDIR OVERLAY SHIM
#
# Prepares the writable layer APPDIR before the prefix is mounted, and
# cleans up after it.
#
# skeleton: creates the directories of the Nix layers' drive_c (five levels
# deep) in APPDIR, writable by everyone. Wine and installers create files in
# them; a directory that exists only in a read-only lower layer would first
# have to be copied up.
#
# install-start-shim: puts the start.exe of SHIM (the hostStartShim package:
# bin/x86_64/start.exe and bin/i686/start.exe) into APPDIR's system32 and
# syswow64, so "start <url>" opens the host browser.
#
# remove-start-shim: removes those copies again, from APPDIR and, where they
# are still the shim's, from the mounted prefix OVERLAY.
#
# A step that fails is reported and the others still run, as they did when
# this was part of the launcher.

usage() {
  echo "usage: nix-overlayfs-upper-layer skeleton APPDIR LOWERDIR... | install-start-shim APPDIR SHIM | remove-start-shim APPDIR OVERLAY SHIM" >&2
  exit 2
}

skeleton() {
  local appdir="$1"
  local lowerdir=""
  local lower_drive_c=""
  local source_dir=""
  local relative_dir=""
  shift

  for lowerdir in "$@"; do
    lower_drive_c="$lowerdir/drive_c"
    [ -d "$lower_drive_c" ] || continue

    while IFS= read -r -d "" source_dir; do
      relative_dir="${source_dir#"$lowerdir"/}"
      [ "$relative_dir" != "$source_dir" ] || continue
      mkdir -p "$appdir/$relative_dir" || true
      chmod a+rwx "$appdir/$relative_dir" || true
    done < <(find "$lower_drive_c" -maxdepth 5 -type d -print0)
  done
}

install_start_shim() {
  local appdir="$1"
  local shim="$2"

  rm -f \
    "$appdir/drive_c/windows/system32/start.exe" \
    "$appdir/drive_c/windows/syswow64/start.exe" || true
  mkdir -p \
    "$appdir/drive_c/windows/system32" \
    "$appdir/drive_c/windows/syswow64" || true
  cp -f "$shim/bin/x86_64/start.exe" "$appdir/drive_c/windows/system32/start.exe" || true
  cp -f "$shim/bin/i686/start.exe" "$appdir/drive_c/windows/syswow64/start.exe" || true
}

remove_start_shim() {
  local appdir="$1"
  local overlay="$2"
  local shim="$3"

  rm -f \
    "$appdir/drive_c/windows/system32/start.exe" \
    "$appdir/drive_c/windows/syswow64/start.exe" || true

  if [ -f "$overlay/drive_c/windows/system32/start.exe" ] \
    && cmp -s "$overlay/drive_c/windows/system32/start.exe" "$shim/bin/x86_64/start.exe"; then
    rm -f "$overlay/drive_c/windows/system32/start.exe" || true
  fi
  if [ -f "$overlay/drive_c/windows/syswow64/start.exe" ] \
    && cmp -s "$overlay/drive_c/windows/syswow64/start.exe" "$shim/bin/i686/start.exe"; then
    rm -f "$overlay/drive_c/windows/syswow64/start.exe" || true
  fi
}

case "${1:-}" in
  skeleton)
    [ "$#" -ge 2 ] || usage
    shift
    skeleton "$@"
    ;;
  install-start-shim)
    [ "$#" -eq 3 ] || usage
    install_start_shim "$2" "$3"
    ;;
  remove-start-shim)
    [ "$#" -eq 4 ] || usage
    remove_start_shim "$2" "$3" "$4"
    ;;
  *)
    usage
    ;;
esac
