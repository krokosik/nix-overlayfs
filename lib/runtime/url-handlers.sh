# Usage:
#   nix-overlayfs-url-handlers filter-schemes < NAMES
#   nix-overlayfs-url-handlers register STATE_DIR SCHEMES_FILE EXECUTABLE_NAME LAUNCHER LABEL
#   nix-overlayfs-url-handlers unregister STATE_DIR
#
# The host side of a package's URL schemes: a hidden .desktop file in
# $XDG_DATA_HOME/applications that hands the URL to the launcher, made the
# user's default for each scheme.
#
# filter-schemes reads candidate scheme names (one per line) and prints the
# usable ones once each, in lower case: valid URI scheme names, without the
# schemes a web browser owns (http, https, ftp, mailto).
#
# register writes STATE_DIR/open-url, which runs LAUNCHER (or, once that store
# path is gone, EXECUTABLE_NAME from PATH) with --nix-overlayfs-open-url, and
# EXECUTABLE_NAME-nix-overlayfs-url-handler.desktop for the schemes listed in
# SCHEMES_FILE, and makes that entry the default for each of them. Handler
# entries STATE_DIR wrote earlier under another executable name are removed.
# LABEL names the package in warnings.
#
# unregister is for packages whose host declares the handler (a NixOS or
# home-manager module): it removes every handler entry STATE_DIR wrote and its
# open-url script.
#
# Removed entries are also dropped from the user's mimeapps.list files.

usage() {
  echo "usage: nix-overlayfs-url-handlers filter-schemes | register STATE_DIR SCHEMES_FILE EXECUTABLE_NAME LAUNCHER LABEL | unregister STATE_DIR" >&2
  exit 2
}

applications_dir="${XDG_DATA_HOME-}/applications"

filter_schemes() {
  awk '
    {
      scheme = tolower($0)
      if (scheme !~ /^[a-z][a-z0-9+.-]*$/) next
      if (scheme == "http" || scheme == "https" || scheme == "ftp" || scheme == "mailto") next
      if (!seen[scheme]++) print scheme
    }
  '
}

# Removes the URL handler entries STATE_DIR wrote earlier, under this or an
# older executable name, except KEEP.
remove_url_handlers() {
  local state_dir="$1"
  local keep="$2"
  local desktop=""
  local -a removed=()

  for desktop in "$applications_dir"/*-nix-overlayfs-url-handler.desktop; do
    [ -f "$desktop" ] || continue
    [ "$desktop" != "$keep" ] || continue
    grep -qxF "Exec=$state_dir/open-url %u" "$desktop" || continue
    rm -f -- "$desktop"
    removed+=("${desktop##*/}")
  done
  [ "${#removed[@]}" -gt 0 ] || return 0

  for desktop in "${removed[@]}"; do
    nix-overlayfs-forget-desktop-entry "$desktop" \
      "${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list" \
      "$applications_dir/mimeapps.list" || true
  done
  update-desktop-database "$applications_dir" >/dev/null 2>&1 || true
}

register() {
  local state_dir="$1"
  local schemes_file="$2"
  local executable_name="$3"
  local launcher="$4"
  local label="$5"
  local desktop_id="$executable_name-nix-overlayfs-url-handler.desktop"
  local desktop_file="$applications_dir/$desktop_id"
  local handler_script="$state_dir/open-url"
  local mime_types=""
  local existing_default=""
  local scheme=""

  remove_url_handlers "$state_dir" "$desktop_file"

  mkdir -p "$applications_dir"
  [ -s "$schemes_file" ] || return 0

  # Prefer this package; after it was garbage collected, use the installed
  # launcher of the same name.
  # shellcheck disable=SC2016
  printf '%s\n' \
    "#!$BASH" \
    "launcher=$launcher" \
    '[ -x "$launcher" ] || launcher="$(command -v '"$executable_name"')" || exit 127' \
    'exec "$launcher" --nix-overlayfs-open-url "$@"' \
    > "$handler_script"
  chmod 755 "$handler_script"

  while IFS= read -r scheme; do
    mime_types="$mime_types""x-scheme-handler/$scheme;"
  done < "$schemes_file"

  printf '%s\n' \
    '[Desktop Entry]' \
    'Type=Application' \
    "Name=$executable_name URL Handler" \
    'NoDisplay=true' \
    "Exec=$handler_script %u" \
    "MimeType=$mime_types" \
    > "$desktop_file"

  update-desktop-database "$applications_dir" >/dev/null 2>&1 || true

  while IFS= read -r scheme; do
    existing_default="$(xdg-mime query default "x-scheme-handler/$scheme" 2>/dev/null || true)"
    if [ -n "$existing_default" ] && [ "$existing_default" != "$desktop_id" ]; then
      echo "warning: x-scheme-handler/$scheme was registered to $existing_default; setting $desktop_id for $label" >&2
    fi
    xdg-mime default "$desktop_id" "x-scheme-handler/$scheme" >/dev/null 2>&1 || true
  done < "$schemes_file"
}

case "${1:-}" in
  filter-schemes)
    [ "$#" -eq 1 ] || usage
    filter_schemes
    ;;
  register)
    [ "$#" -eq 6 ] || usage
    shift
    register "$@"
    ;;
  unregister)
    [ "$#" -eq 2 ] || usage
    remove_url_handlers "$2" ""
    rm -f -- "$2/open-url"
    ;;
  *)
    usage
    ;;
esac
