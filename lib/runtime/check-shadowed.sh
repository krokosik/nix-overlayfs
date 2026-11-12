# Usage: nix-overlayfs-check-shadowed APPDIR STATE_DIR LOWERDIR...
#
# Finds files in the writable layer's drive_c/windows that hide a file the
# read-only Nix layers would otherwise show. LOWERDIRs are given in overlay
# priority order (highest first), as in fuse-overlayfs' lowerdir= option. Must
# run before the prefix is mounted.
#
# Such files are usually Wine builtin DLLs that a runtime prefix update copied
# into the writable layer; they keep hiding the Nix layers after every rebuild
# (for example Wine's d3d11.dll over DXVK's). NIX_OVERLAYFS_SHADOWED_FILES
# selects what happens:
#   prune-builtin (default)  move Wine builtin copies and identical copies
#                            aside, report the others
#   prune                    move every hiding file aside
#   warn                     only report
#   ignore                   do nothing
# Files are moved to STATE_DIR/shadowed/<time>/, never deleted; the report is
# STATE_DIR/shadowed-files.
#
# "Hides" means what the mounted prefix would show without the writable file:
# the path is resolved through the layers as overlayfs does - whiteouts
# (.wh.<name> files or 0/0 character devices) and opaque directories
# (.wh..wh..opq or an opaque xattr) end the lookup, and a non-directory entry
# hides everything below it. Opaque directories in the writable layer, also
# above drive_c/windows, hide every layer below.
#
# The whole scan and all decisions come first; if anything cannot be read,
# the script exits non-zero before it moves a file.

if [ "$#" -lt 2 ]; then
  echo "usage: nix-overlayfs-check-shadowed APPDIR STATE_DIR LOWERDIR..." >&2
  exit 2
fi

appdir="$1"
state_dir="$2"
shift 2
lowerdirs=("$@")

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

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

fail() {
  echo "error: nix-overlayfs: $*; nothing was moved" >&2
  exit 1
}

# --- reading the layers ------------------------------------------------------

declare -A opaque_cache=()

# 0: opaque, 1: not opaque; exits on an unreadable directory.
is_opaque() {
  local dir="$1" name value err
  if [ -n "${opaque_cache[$dir]+x}" ]; then
    return "${opaque_cache[$dir]}"
  fi
  if [ -e "$dir/.wh..wh..opq" ] || [ -L "$dir/.wh..wh..opq" ]; then
    opaque_cache[$dir]=0
    return 0
  fi
  for name in trusted.overlay.opaque user.overlay.opaque user.fuseoverlayfs.opaque; do
    if value="$(getfattr --only-values --absolute-names -n "$name" -- "$dir" 2>"$work/getfattr.err")"; then
      if [ "$value" = y ]; then
        opaque_cache[$dir]=0
        return 0
      fi
    else
      err="$(cat "$work/getfattr.err")"
      case "$err" in
        *"No such attribute"* | *"Operation not supported"* | *"No data available"*) ;;
        *) fail "cannot read $name of $dir: $err" ;;
      esac
    fi
  done
  opaque_cache[$dir]=1
  return 1
}

# Whether LAYER has a whiteout for the relative PATH.
is_whiteout() {
  local layer="$1" path="$2" parent name
  case "$path" in
    */*) parent="${path%/*}/" name="${path##*/}" ;;
    *) parent="" name="$path" ;;
  esac
  if [ -e "$layer/$parent.wh.$name" ] || [ -L "$layer/$parent.wh.$name" ]; then
    return 0
  fi
  [ -c "$layer/$path" ] && [ "$(stat -c '%t:%T' -- "$layer/$path")" = "0:0" ]
}

# Resolves the relative PATH through the lower layers, below the writable
# layer, as the mounted prefix would. Sets visible_layer to the layer whose
# entry is visible ("" if none) and visible_kind to file, dir or other.
resolve_lower() {
  local path="$1" rest="$1" prefix="" component layer entry
  local -a active=("${lowerdirs[@]}") next
  visible_layer=""
  visible_kind=""

  while [[ "$rest" == */* ]]; do
    component="${rest%%/*}"
    rest="${rest#*/}"
    prefix="${prefix:+$prefix/}$component"
    # An opaque directory of the writable layer hides all lower layers.
    if is_opaque "$appdir/$prefix"; then
      return 0
    fi
    next=()
    for layer in "${active[@]}"; do
      if is_whiteout "$layer" "$prefix"; then
        break
      fi
      entry="$layer/$prefix"
      if [ -L "$entry" ] || { [ -e "$entry" ] && [ ! -d "$entry" ]; }; then
        break
      fi
      if [ -d "$entry" ]; then
        next+=("$layer")
        if is_opaque "$entry"; then
          break
        fi
      fi
    done
    active=("${next[@]}")
    [ "${#active[@]}" -gt 0 ] || return 0
  done

  for layer in "${active[@]}"; do
    if is_whiteout "$layer" "$path"; then
      return 0
    fi
    entry="$layer/$path"
    if [ -L "$entry" ]; then
      visible_layer="$layer" visible_kind=other
      return 0
    elif [ -f "$entry" ]; then
      visible_layer="$layer" visible_kind=file
      return 0
    elif [ -e "$entry" ]; then
      visible_layer="$layer" visible_kind=other
      return 0
    fi
  done
}

# winebuild writes this signature at offset 0x40 of every builtin PE module.
is_wine_builtin() {
  [ "$(dd if="$1" bs=1 skip=64 count=16 status=none | tr -d '\0')" = "Wine builtin DLL" ]
}

# --- scan and decide -----------------------------------------------------------

find "$upper_windows" -type f -print0 > "$work/files" \
  || fail "cannot list $upper_windows"
mapfile -d '' -t upper_files < "$work/files"

declare -a move_paths=() report_lines=()
kept=0
for upper_file in "${upper_files[@]}"; do
  relative="${upper_file#"$appdir"/}"
  resolve_lower "$relative"
  [ -n "$visible_layer" ] || continue

  if [ "$visible_kind" != file ]; then
    kind=other
  elif cmp -s -- "$upper_file" "$visible_layer/$relative"; then
    kind=identical
  elif is_wine_builtin "$upper_file"; then
    kind=wine-builtin
  else
    kind=other
  fi

  if [ "$mode" = prune ] || { [ "$mode" = prune-builtin ] && [ "$kind" != other ]; }; then
    move_paths+=("$relative")
    report_lines+=("moved	$kind	$relative	$visible_layer")
  else
    kept=$((kept + 1))
    report_lines+=("hides	$kind	$relative	$visible_layer")
  fi
done

# --- act -----------------------------------------------------------------------

mkdir -p -- "$state_dir"
report="$state_dir/shadowed-files"
backup="$state_dir/shadowed/$(date +%Y%m%d-%H%M%S)"

for relative in "${move_paths[@]}"; do
  mkdir -p -- "$backup/$(dirname -- "$relative")"
  mv -- "$appdir/$relative" "$backup/$relative"
done

: > "$report.tmp.$$"
if [ "${#report_lines[@]}" -gt 0 ]; then
  printf '%s\n' "${report_lines[@]}" > "$report.tmp.$$"
fi
mv -f -- "$report.tmp.$$" "$report"

if [ "${#move_paths[@]}" -gt 0 ]; then
  echo "nix-overlayfs: moved ${#move_paths[@]} file(s) that hid the Nix layers to $backup (list: $report)" >&2
fi
if [ "$kept" -gt 0 ]; then
  echo "warning: nix-overlayfs: $kept file(s) in the writable layer hide the Nix layers; see $report" >&2
  echo "warning: nix-overlayfs: set NIX_OVERLAYFS_SHADOWED_FILES=prune to move them aside" >&2
fi
