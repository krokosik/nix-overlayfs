# Usage:
#   nix-overlayfs-registry merge APPDIR SIGNATURE SIGNATURE_NEXT SOURCE...
#   nix-overlayfs-registry upsert-section REGISTRY SECTION TMPDIR < BODY
#   nix-overlayfs-registry string VALUE
#
# merge: the writable layer APPDIR holds the prefix's registry files
# (system.reg, user.reg, userdef.reg), merged from the registry files of the
# Nix layers and APPDIR itself (SOURCEs, lowest priority first). Writes the
# resolved Nix layer paths to SIGNATURE_NEXT and merges again only when they
# differ from SIGNATURE (the last successful merge) or a registry file is
# missing. A failed merge removes SIGNATURE, so the next call merges again;
# it still exits 0, so the launch goes on.
#
# upsert-section: replaces the key SECTION of the Wine registry file REGISTRY
# (for example Software\\Wine\\WineBrowser, with doubled backslashes as in the
# file) with BODY, the key's values in the file's own syntax, and gives it the
# current time. Creates REGISTRY if needed. TMPDIR holds the files it builds.
#
# string: prints VALUE as a quoted registry string value.

usage() {
  echo "usage: nix-overlayfs-registry merge APPDIR SIGNATURE SIGNATURE_NEXT SOURCE... | upsert-section REGISTRY SECTION TMPDIR | string VALUE" >&2
  exit 2
}

merge() {
  local appdir="$1"
  local signature="$2"
  local signature_next="$3"
  local source=""
  shift 3

  for source in "$@"; do
    if [ "$source" = "$appdir" ]; then
      continue
    fi
    readlink -f "$source" || true
  done > "$signature_next"

  if [ -f "$appdir/system.reg" ] \
    && [ -f "$appdir/user.reg" ] \
    && [ -f "$appdir/userdef.reg" ] \
    && [ -f "$signature" ] \
    && cmp -s "$signature" "$signature_next"; then
    return 0
  fi

  # A failed merge does not stop the launch (merge-wine-registries reports
  # its own errors), but it is not recorded either: the next launch merges
  # again.
  if merge-wine-registries "$appdir" "$@"; then
    cp -f "$signature_next" "$signature"
  else
    echo "warning: nix-overlayfs: merging the registry of $appdir failed; it is merged again on the next launch" >&2
    rm -f "$signature"
  fi
}

upsert_section() {
  local registry="$1"
  local section="$2"
  local tmpdir="$3"
  local body_file="$tmpdir/nix-overlayfs-user-reg-body.$$"
  local next_registry="$tmpdir/nix-overlayfs-user-reg.$$"

  cat > "$body_file"
  mkdir -p "$(dirname "$registry")"

  if [ -f "$registry" ]; then
    NIX_OVERLAYFS_USER_REG_SECTION="[$section]" awk '
      BEGIN { section = ENVIRON["NIX_OVERLAYFS_USER_REG_SECTION"] }
      /^\[/ { skip = ($0 == section || substr($0, 1, length(section) + 1) == section " ") }
      !skip { print }
    ' "$registry" > "$next_registry"
  else
    printf '%s\n\n' 'WINE REGISTRY Version 2' > "$next_registry"
  fi

  {
    printf '\n[%s] %s\n' "$section" "$(date +%s)"
    cat "$body_file"
  } >> "$next_registry"

  mv "$next_registry" "$registry"
  rm -f "$body_file"
}

registry_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

case "${1:-}" in
  merge)
    [ "$#" -ge 4 ] || usage
    shift
    merge "$@"
    ;;
  upsert-section)
    [ "$#" -eq 4 ] || usage
    upsert_section "$2" "$3" "$4"
    ;;
  string)
    [ "$#" -eq 2 ] || usage
    registry_string "$2"
    ;;
  *)
    usage
    ;;
esac
