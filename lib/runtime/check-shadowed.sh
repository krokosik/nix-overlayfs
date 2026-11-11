# Usage: nix-overlayfs-check-shadowed APPDIR STATE_DIR LOWERDIR...
#
# Finds files in the writable layer's drive_c/windows that hide a file of the
# read-only Nix layers. LOWERDIRs are given in overlay priority order (highest
# first), as in fuse-overlayfs' lowerdir= option. Must run before the prefix is
# mounted.
#
# Such files are usually Wine builtin DLLs that a runtime prefix update copied
# into the writable layer; they keep hiding the Nix layers after every rebuild
# (for example Wine's d3d11.dll over DXVK's). NIX_OVERLAYFS_SHADOWED_FILES
# selects what happens:
#   prune-builtin (default)  move Wine builtin copies aside, warn about others
#   prune                    move every hiding file aside
#   warn                     only report
#   ignore                   do nothing
# Files identical to the layer below are harmless today but would hide the
# next change, so both prune modes remove them as well. Moved files go to
# STATE_DIR/shadowed/<time>/, the report to STATE_DIR/shadowed-files.

if [ "$#" -lt 2 ]; then
  echo "usage: nix-overlayfs-check-shadowed APPDIR STATE_DIR LOWERDIR..." >&2
  exit 2
fi

appdir="$1"
state_dir="$2"
shift 2

mode="${NIX_OVERLAYFS_SHADOWED_FILES:-prune-builtin}"
case "$mode" in
  prune-builtin | prune | warn | ignore) ;;
  *)
    echo "error: NIX_OVERLAYFS_SHADOWED_FILES must be one of: prune-builtin, prune, warn, ignore" >&2
    exit 2
    ;;
esac
[ "$mode" != ignore ] || exit 0

upper_windows="$appdir/drive_c/windows"
[ -d "$upper_windows" ] || exit 0

# winebuild writes this signature at offset 0x40 of every builtin PE module.
is_wine_builtin() {
  [ "$(dd if="$1" bs=1 skip=64 count=16 status=none 2>/dev/null | tr -d '\0')" = "Wine builtin DLL" ]
}

mkdir -p -- "$state_dir"
report="$state_dir/shadowed-files"
report_next="$report.tmp.$$"
backup="$state_dir/shadowed/$(date +%Y%m%d-%H%M%S)"
: > "$report_next"

moved=0
removed=0
kept=0

move_aside() {
  local relative="$1"
  mkdir -p -- "$backup/$(dirname -- "$relative")"
  mv -- "$appdir/$relative" "$backup/$relative"
  moved=$((moved + 1))
}

# Files below an opaque directory (deleted, then recreated in the writable
# layer) hide nothing; fuse-overlayfs marks those with a whiteout file or an
# xattr, depending on what the filesystem supports.
opaque_dirs=()
while IFS= read -r -d '' marker; do
  opaque_dirs+=("$(dirname -- "$marker")")
done < <(find "$upper_windows" -name '.wh..wh..opq' -print0)
while IFS= read -r line; do
  case "$line" in
    "# file: "*) opaque_dirs+=("${line#"# file: "}") ;;
  esac
done < <(getfattr --absolute-names -R -m '^(trusted|user)\.(overlay|fuseoverlayfs)\.opaque$' -d "$upper_windows" 2>/dev/null || true)

below_opaque_dir() {
  local file="$1" dir
  for dir in "${opaque_dirs[@]}"; do
    case "$file" in
      "$dir"/*) return 0 ;;
    esac
  done
  return 1
}

while IFS= read -r -d '' upper_file; do
  relative="${upper_file#"$appdir"/}"
  if [ "${#opaque_dirs[@]}" -gt 0 ] && below_opaque_dir "$upper_file"; then
    continue
  fi
  for lowerdir in "$@"; do
    lower_file="$lowerdir/$relative"
    [ -f "$lower_file" ] || continue

    if cmp -s -- "$upper_file" "$lower_file"; then
      if [ "$mode" != warn ]; then
        rm -f -- "$upper_file"
        removed=$((removed + 1))
      fi
      break
    fi

    kind=other
    if is_wine_builtin "$upper_file"; then
      kind=wine-builtin
    fi

    if [ "$mode" = prune ] || { [ "$mode" = prune-builtin ] && [ "$kind" = wine-builtin ]; }; then
      move_aside "$relative"
      printf 'moved\t%s\t%s\t%s\n' "$kind" "$relative" "$lowerdir" >> "$report_next"
    else
      kept=$((kept + 1))
      printf 'hides\t%s\t%s\t%s\n' "$kind" "$relative" "$lowerdir" >> "$report_next"
    fi
    break
  done
done < <(find "$upper_windows" -type f -print0)

mv -f -- "$report_next" "$report"

if [ "$moved" -gt 0 ]; then
  echo "nix-overlayfs: moved $moved file(s) that hid the Nix layers to $backup (list: $report)" >&2
fi
if [ "$removed" -gt 0 ]; then
  echo "nix-overlayfs: removed $removed file(s) identical to the Nix layers from the writable layer" >&2
fi
if [ "$kept" -gt 0 ]; then
  echo "warning: nix-overlayfs: $kept file(s) in the writable layer hide the Nix layers; see $report" >&2
  echo "warning: nix-overlayfs: set NIX_OVERLAYFS_SHADOWED_FILES=prune to move them aside" >&2
fi
