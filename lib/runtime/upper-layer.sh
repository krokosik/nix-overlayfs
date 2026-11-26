# Usage:
#   nix-overlayfs-upper-layer skeleton APPDIR LOWERDIR...
#   nix-overlayfs-upper-layer clean-start-shim APPDIR SHIM
#
# Prepares the writable layer APPDIR before the prefix is mounted.
#
# skeleton: creates the directories of the Nix layers' drive_c (five levels
# deep) in APPDIR, writable by everyone. Wine and installers create files in
# them; a directory that exists only in a read-only lower layer would first
# have to be copied up.
#
# clean-start-shim: the start.exe shim of SHIM (the hostStartShim package:
# bin/x86_64/start.exe and bin/i686/start.exe), with which "start <url>"
# opens the host browser, comes from the launcher's integration layer.
# Earlier launchers copied the shim into APPDIR's system32 and syswow64 for
# each session; a copy left there (a session that was killed) is removed, so
# it does not hide the layer's. Other files are left alone.
#
# A step that fails is reported and the others still run, as they did when
# this was part of the launcher.

usage() {
  echo "usage: nix-overlayfs-upper-layer skeleton APPDIR LOWERDIR... | clean-start-shim APPDIR SHIM" >&2
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

clean_start_shim() {
  local appdir="$1"
  local shim="$2"
  local copy=""

  for copy in system32:x86_64 syswow64:i686; do
    if [ -f "$appdir/drive_c/windows/${copy%%:*}/start.exe" ] \
      && cmp -s "$appdir/drive_c/windows/${copy%%:*}/start.exe" "$shim/bin/${copy#*:}/start.exe"; then
      rm -f "$appdir/drive_c/windows/${copy%%:*}/start.exe" || true
    fi
  done
}

case "${1:-}" in
  skeleton)
    [ "$#" -ge 2 ] || usage
    shift
    skeleton "$@"
    ;;
  clean-start-shim)
    [ "$#" -eq 3 ] || usage
    clean_start_shim "$2" "$3"
    ;;
  *)
    usage
    ;;
esac
