# Usage: nix-overlayfs-webview2-check-install PREFIX VERSION ARCHITECTURE
#
# Succeeds if the Wine prefix PREFIX has WebView2 VERSION for ARCHITECTURE
# (x64, x86 or arm64): a regular file
#   drive_c/Program Files[ (x86)]/Microsoft/EdgeWebView/Application/VERSION/msedgewebview2.exe
# whose PE header names that machine. Other version directories are ignored.
prefix=$1
version=$2
architecture=$3

case "$architecture" in
  x64) expected=8664 ;;
  x86) expected=014c ;;
  arm64) expected=aa64 ;;
  *)
    echo "error: unknown WebView2 architecture '$architecture' (x64, x86 or arm64)" >&2
    exit 2
    ;;
esac

# The COFF Machine field of the PE file $1, as four hex digits; empty if $1 is
# not a PE file. e_lfanew (offset 0x3c) points to "PE\0\0", followed by Machine.
pe_machine() {
  local file=$1 offset signature
  [ "$(od -An -c -N2 "$file" | tr -d ' ')" = MZ ] || return 0
  offset=$(od -An -tu4 --endian=little -j60 -N4 "$file" | tr -d ' ')
  [ -n "$offset" ] || return 0
  signature=$(od -An -tx1 -j"$offset" -N4 "$file" 2>/dev/null | tr -d ' ') || return 0
  [ "$signature" = 50450000 ] || return 0
  od -An -tx2 --endian=little -j$((offset + 4)) -N2 "$file" | tr -d ' '
}

found=""
for programFiles in "Program Files" "Program Files (x86)"; do
  file="$prefix/drive_c/$programFiles/Microsoft/EdgeWebView/Application/$version/msedgewebview2.exe"
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    found=1
    machine=$(pe_machine "$file")
    if [ "$machine" = "$expected" ]; then
      echo "WebView2 $version ($architecture) installed: $file"
      exit 0
    fi
    echo "warning: $file: PE machine '${machine:-not a PE file}', expected $expected ($architecture)" >&2
  fi
done

if [ -z "$found" ]; then
  echo "error: WebView2 $version was not installed (no EdgeWebView/Application/$version/msedgewebview2.exe)" >&2
else
  echo "error: no $architecture msedgewebview2.exe for WebView2 $version" >&2
fi
exit 1
